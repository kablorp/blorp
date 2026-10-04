# Discovery Redesign: Per-Module Parses into Typed Syntax Trees

This is a design for review. The typed-tree path is not implemented yet; the
syntax prerequisite M-1 has landed, and M0 measured a throwaway body-parser
prototype. M1 to M7 remain open. It replaces the data model of
[`DISCOVERY_TABLES_DESIGN.md`](DISCOVERY_TABLES_DESIGN.md) (one builder threaded
through every module, a flat node table and about 50 side tables) with:

- one pure parse per module, producing a typed syntax tree or the diagnostics
  that reject the module;
- a module-graph walk that calls it;
- one link step that produces what later stages read.

The code below is real Blorp: every type is written out in full. Function
bodies are given only where the shape matters.

- **Current implementation checked at:** main `1a767d0c7` (2026-10-03).
  The census and initial cost probes below are historical measurements at
  `519e7311c`, not measurements of this revision.
- **Counts:** taken on the self-compile inputs (`blorp/src/main.brp`, 449
  modules, prelude and tuple implicit modules) with a census tool over the
  then-current tables. Appendix A gives the census; Appendix B gives the
  allocation probes.
- **Decisions:** revised after an independent review of the first version;
  the decisions taken are in section 10.
- **Product direction:** ordinary `record` is the target nominal product
  ([`FIXED_LAYOUT_ROADMAP.md`](FIXED_LAYOUT_ROADMAP.md)). The proposed syntax
  below uses records for name and syntax values. Its historical M0 prototype
  used several `struct` values, so its costs do not price this exact shape.
- **Precedence:** where this document and a later implementation disagree,
  the implementation and its tests win, and this document is fixed in the
  same change.

## Contents

0. Decisions in brief
1. Goals, principles, non-goals, and what the redesign replaces
2. The pipeline
3. The syntax types
4. The output: the contract with later stages
5. Interning and literal values
6. The legacy adapter and the parity gates
7. Expected cost
8. Migration plan
9. Remaining disagreements
10. Decisions taken

Appendix A: node census. Appendix B: allocation probes.

## 0. Decisions in brief

1. **Typed trees are the output.** Bodies, written types and patterns stay
   trees after discovery. They are not flattened into a node table. Every
   reader in the pipeline (resolution, typecheck, Core lowering, the legacy
   adapter) walks a body in its structure. A node table makes each of them
   rebuild that structure from kinds and child positions. The adapter's 25
   derived owner indexes (`DeclarationReader`) show the cost. `AGENTS.md`
   already names this as the case where a table does not pay: "every
   consumer immediately joins [it] back into the original shape".
2. **Every construct a later stage elaborates or keys a fact on carries an
   id.** The family is fixed by the construct, and the list is section 3.3:
   - `DefinitionId`, `ImportId`;
   - `StatementId`, `BlockId`;
   - `ExpressionId`, `PatternId`, `WrittenTypeId`, `DimensionId`;
   - `NameUseId`, `BinderId`, `TypeBinderId`.

   An id is packed from (module, index within the module). A program-wide
   id is the module's base plus the local index. A name's spelling is a
   `SpellingId`, packed the same way. A module's ids do not depend on any
   other module, so modules can be parsed independently and later in
   parallel. This borrows rustc's `HirId` = (owner, local id).
3. **Ids live behind one opaque boundary.** `IdMint` is the only maker of
   ids, and only the parser may import it. A node gets its id from the mint
   as the node is built, in the same step. No id is ever predicted, read from
   a length, or visible before its node exists.
4. **One pure function parses a module:** `parse_module(module, text) ->
   ParsedSource`, with the lexer inside it. The module-graph walk is the only
   impure part: it reads files and resolves requests.
5. **A module with a syntax error has no tree.** Discovery reports its
   diagnostics, exactly as today: the parser continues after an error with
   placeholders that never leave it. The tree types contain no recovery forms
   and no missing names. A discovery with any problem that stops compilation
   produces a failure report instead of a program.
6. **Names are interned per module and merged once at link.** A tree holds a
   `SpellingId`; `program.name_id(spelling)` gives the program-wide `NameId`.
   Discovery does not intern literal texts (the backend pools strings). The
   tree stores literal values in checked form. The seeded vocabulary of the
   old compiler moves into the legacy adapter.
7. **The link step is not a flatten, and nothing is checked at freeze.** Link
   interns names, computes the program-wide id bases, and builds the module,
   request and name tables. It cannot fail. The 2,800 lines of `invariants/`
   are deleted: each violation they check is unrepresentable or guaranteed by
   the mint. An id census proves the minting discipline, as a corpus test and
   in debug builds at link.
8. **Prerequisites in the language.**
   - Assignment is a statement only. `=` in an expression position
     (`xs = [a = 1]`, `print(ys[0] = 3)`, `if a = 1:`) is a parse error in
     both parsers, and the language has no named call arguments (landed in
     `d460bac5f`).
   - M-1 landed in `020b95d90`: both parsers reject the remaining forms
     that only typecheck rejected, and implicit type parameters are removed
     (auto-generalization and bounded arguments outside an `implements`
     receiver).

   With both landed, the tree types need no form that exists only to be
   rejected.
9. **The legacy adapter becomes a structural map from tree to old AST.** It
   stays in `blorp/src/compiler/discovery_adapter.brp`, run by
   `blorp/src/compiler/discovery_front_end.brp`; M3 to M6 rewrite both in
   place over the trees, and they are deleted when typecheck reads the trees
   directly. These two are the only compiler modules that import
   `compiler_new`, as `temporary_cross_owner_imports` in
   `blorp/source_ownership.json` lists.
10. **The tree path becomes the default only within a hard ceiling** on retired
    instructions, peak RSS and wall time. This is an internal table-to-tree
    selection inside the already-default discovery stage, not a return of
    `BLORP_FRONT_END`. The ceiling is not loosened for any compiler change.
    Since 2026-10-02 M6 waits on the compiler work of
    [`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md): its increments 1 to 4, and
    increment 5 if M0 re-measured after increment 4 still needs it. M1 to M5
    do not wait (section 10, flip timing).

## 1. Goals, principles, non-goals, and what the redesign replaces

### Goals

The goal is output that lets the following stages of the compiler be
straightforward and not re-do work from earlier stages. That breaks down
into:

1. **Clean, understandable, correct code**, in the stage and in its readers.
   The organization of the code and the data model comes first.
2. **Illegal states unrepresentable by construction.** No freeze check stands
   in for a type, and nothing is left half-way.
3. **Later stages read discovery's output directly.** Resolution resolves names
   by walking typed syntax, and typecheck keys types by ids discovery issued.
   Neither re-derives a fact that discovery had: no digits to re-parse, no
   arity to re-check, no parent to inspect.
4. **The stage knows nothing about the old compiler.** Glue lives in
   `blorp/src/compiler/discovery_front_end.brp` and `discovery_adapter.brp`,
   the only compiler modules that import the stage.
5. **Design first; cost second.** Where today's compiler makes a clean shape
   expensive, the cost and the compiler work that recovers it go into a ledger
   (section 7). The default still flips only within a hard ceiling.

### Principles

- **A syntactic category is a type.** Statements, expressions, patterns,
  written types, dimensions and declarations are each a record with a union of
  forms. Every form holds exactly its parts:
  - `Option` for an optional part;
  - a `List` for a sequence of any length;
  - a non-empty or fixed-arity shape for a sequence the grammar bounds
    (section 3.1);
  - a union where the grammar offers alternatives.

  Readers match exhaustively, so they never need an arity check, a
  child-role table or a "child 2 when written" convention. (OCaml's typed
  intermediate forms; rustc's `ExprKind`.)
- **A node has its common fields in a record and its form in a union**:
  `Expression {id, span, kind}`. This is rustc's `Expr {id, kind, span}` and
  OCaml's `expression = {exp_desc; exp_loc; ...}`.
- **The id rule.** Every construct that a later stage elaborates or keys a
  fact on carries an id of its family. Section 3.3 lists every such
  construct. A construct not on the list carries no id, and nothing on the
  list lacks one.
- **Ids are managed exclusively behind the opaque boundary.** Only `IdMint`
  makes an id. A node's record is built in the step that mints its id
  (section 3.15).
- **A name says its role in its type.**
  - `NameUse` is a reference whose meaning a later stage decides: resolution
    by scope, or typecheck by type (a field or a method).
  - `Binder` introduces a local value, and `TypeBinder` a type parameter.
  - `WrittenName` is a name that no later stage resolves: a declared name,
    a module alias, a path part.
- **Later stages never construct syntax.** They read the trees and key their
  own facts by the ids in them. Every syntax value outside `parse/` is one
  the parser built. Tests are the only other code that builds trees.
- **Failure is loud in every build.** A read of an id the program issued that
  misses is an internal compiler error in debug and release alike (section
  4.5). There are no fallback rows.
- **One fact, one place.**
  - A module's path, origin and package live in its module record.
  - An import's target lives in that module's import targets, one per import.
  - A name's text lives once in the name table.
  - The definitions index holds references to the declaration records, not
    copies.
- **Deterministic.** Module order is roots, then implicit modules, then
  imports breadth first in source order. Ids within a module follow source
  order (names, binders) or completion order (nodes and definitions). Names
  are merged in module order. Output depends only on the inputs, never on
  scheduling.

### Non-goals

- **The current LSP integration.** The LSP will likely share compiler
  utilities piecemeal rather than invoke the compiler's stages directly. This
  design neither serves nor constrains today's LSP.
- **Comments and layout trivia.** The trees hold no comments, blank lines or
  spacing; spans are their only link to the source text. The formatter keeps
  the old parser until a separate design gives it a lossless tree or a trivia
  table.
- **An error-tolerant tree.** A module with a syntax error has no tree.
  Editing support inside a broken module needs its own lossless,
  error-tolerant syntax, which is a tooling design.
- **Incremental re-discovery.** Per-module parses and per-module ids make it
  possible later. It is not designed here.
- **What typecheck and Core lowering read.** Section 4.7 lists the effects on
  resolution. The reads of typecheck and Core lowering are specified when
  those stages are designed.
- **Name resolution and types.** Those are resolution's and typecheck's.

### What the redesign replaces, and why each goes

| Today | Why it goes | Replaced by |
| --- | --- | --- |
| `DiscoveryBuilder`, a flat record of 61 fields threaded through every lexer and parser call, and every module | It is one owner of all state because rows had to be appended in place. That forced the parse of every module into one sequential value, mixed transient parse state with output, and made "the last node appended" a protocol. | A per-module `ParseState` (cursor, id mint, spellings, diagnostics) that dies with the parse; trees returned by value |
| The five builder threading rules and `tools/builder_rule_probe.brp` | They encode where the compiler copies a builder. A routine had to be written to the rules, and a broken rule meant an O(n) copy per append. | Ordinary values returned from functions. The cost of those returns is in the ledger (section 7), not in a rule list. |
| Openings and closings (`open_module`/`close_module`, `ImportOpening`, `ForeignBlockOpening`, the per-class definition openings, `OwnedRows`, `TypeParametersStart`) | They existed to append a parent's row before or after its children with the right ranges. Closing once was a caller obligation that only debug builds checked. | A parent record built after its children, holding them. Nothing is open. |
| Predicted ids (`next_definition_id`, `next_module_id`, `*_id_at_row(length())` in every opening, `interned_path_id` before `intern_path`) | The id was read before the row existed, so its correctness depended on no other append in between. | `IdMint`: the id is minted in the step that builds its node (section 3.15) |
| `NodeRow {kind, span, payload: Int, children: RowRange}`, `node_schema`, `ChildArity`, `NodePayloadReference`, `NameSpanRule`, `node_kind_classes` | The payload's meaning and the children's roles depended on the kind. Appenders were typed by kind class, but readers still decoded positions. | One record and union per category; payloads are typed fields |
| The child stack (`child_stack`, `child_stack_depth`, `push_last_node`, `last_node_id`, `discard_last_leaf_node`) | It was needed to build post-order rows without a local list of child ids. | Parse functions return their node |
| Sorted side tables read by binary search through a closure (`bound_qualifiers`, `import_targets`, `import_aliases`, `node_name_spans`, `else_keywords`, `module_packages`, ...) | They expressed optional relationships when a struct row could hold no `Option`. Correctness depended on append order, which `SideTableUnsorted` checked at freeze. | `Option` fields in the records that own them |
| `DimensionNameRow` (`#N` beside `N`) and the 236-name seeded vocabulary | Both exist only for the old compiler's name table. | Moved into the legacy adapter (section 6) |
| Transient tables (`tokens`, `token_cursor`, `pending_docstrings`, `pending_annotations`, `interpolations`, `interpolation_parts`, `interpolation_texts`) and tokens of interpolation holes appended after the end-of-file token | Parse state lived in the output's owner. | `ParseState` and `LexedModule`, which never reach the output; a hole is lexed into its own token list |
| `freeze` and `invariants/` (2,800 lines, about 30 violation kinds), `TableInvariantViolation`, `FreezeOutcome.TableInvariantsViolated` | They checked at freeze what construction did not guarantee. | Construction guarantees each fact (section 4.6). Freeze is gone. |
| `UNREACHABLE_*` fallback rows and `report_unreachable_lookup` in about 20 accessors | A release build continued with an invented row after a compiler defect. | Readers hold the node. The few by-id reads return `Option`, and a miss is an internal compiler error in every build (section 4.5). |
| `SourceId` beside `ModuleId`; `PathId` and the paths table | Every admitted source is exactly one module, and paths were interned only to be stored in rows. | `ModuleId` names the source too; a path is a `String` in the one record that owns it |
| `ResolutionDiagnosticRow` table | An import's or request's failure is its outcome. | `ImportOutcome`, `RootOutcome` and `ImplicitOutcome` hold their failures |
| Literal texts in a `literals` table, digits re-parsed by every reader | Typecheck, CTFE and the concurrency parameters each parse digits again. | Checked literal values in the tree (section 5.2) |

## 2. The pipeline

### 2.1 Order of work

```
discover(provider, lookup, roots, implicit)
  ├─ for each root:              resolve → read → admit → parse_module → record outcome
  ├─ for each implicit module:   the same, as an implicit request
  ├─ while a loaded module's imports are unvisited, take the next in id order:
  │     for each of its imports in source order: resolve → (load if new) → outcome
  └─ link: the program, or the report of what stops it
```

- **The walk** (`sources/module_walk.brp`) is the only impure loop. It owns:
  - the provider;
  - the directory listings it has read;
  - the by-path index (`Dict[String, ModuleId]`), so that each canonical path
    loads once;
  - the queue of modules whose imports are not resolved yet.

  Nothing it holds is part of the output. Modules load one at a time, and a
  module's id is the next index when it loads.
- **`parse_module(module, text)`** is pure. It lexes, then parses (section
  2.3). It needs the `ModuleId` because spans and ids carry it, but it does
  not need the path: path, origin and package are module-graph facts, stored
  by the walk.
- **Imports are resolved per module.** A module's imports, or a rejected
  module's kept imports, are visited together in source order when the
  module comes off the queue. Each import gets exactly one outcome, built by
  mapping over the module's import list. The queue visits modules in the
  same order as today's import queue, so every module id is unchanged.
- **Link** (`link/link.brp`) runs once, after the queue is empty. It needs
  every module visited, and the types require that: it takes a
  `CompletedWalk`, which only the walk's last step produces.

### 2.2 `pipeline.brp` as it would read

```blorp
-- The discovery stage, in order:
--
--   1. roots, in the order given;
--   2. implicit modules, in the order given;
--   3. the imports of every loaded module, module by module in load order
--      and, within a module, in source order; each canonical path loads once;
--   4. link: the program, or the report of what stops it.
--
-- Loading a module admits its source and parses it (`parse/module_parser`,
-- a pure function of the module's id and text). The walk's mechanics live in
-- `sources/module_walk`; the outcome's types in `link/program`.
import:
	link/link: link
	link/program: DiscoveryOutcome
	sources/module_walk:
		ModuleWalk,
		completed_walk,
		empty_module_walk,
		has_unvisited_module,
		load_implicit,
		load_root,
		visit_next_module,
	sources/source_provider: RootRequest, SourceLookupRoots, SourceProvider, user_root


---
The standard-library modules every compilation loads without an import, by
name. The existing front end seeds `prelude` and `tuple` (and `test` for
`blorp test`); this stage restates them because it must not import the old
compiler, and `compiler-new-parity` keeps the two lists equal.
---
record ImplicitModules {
	module_names: List[String]
}


---
Discovers every module reachable from `roots` (source paths of user modules)
and the `implicit` modules through `provider`, then links them.
---
func discover[Provider: SourceProvider](
	provider: Provider,
	lookup: SourceLookupRoots,
	roots: List[String],
	implicit: ImplicitModules,
) -> DiscoveryOutcome:
	discover_placed_roots(provider, lookup, roots.map(pure func(path): user_root(path)), implicit)


---
`discover` for roots whose placement the caller states.
---
func discover_placed_roots[Provider: SourceProvider](
	provider: Provider,
	lookup: SourceLookupRoots,
	roots: List[RootRequest],
	implicit: ImplicitModules,
) -> DiscoveryOutcome:
	var walk: ModuleWalk = empty_module_walk(lookup)

	for root in roots:
		walk = walk.load_root(provider, root)

	for module_name in implicit.module_names:
		walk = walk.load_implicit(provider, module_name)

	while walk.has_unvisited_module():
		walk = walk.visit_next_module(provider)

	link(walk.completed_walk())
```

`completed_walk` returns a `CompletedWalk`, and only when the queue is empty:
it is the one way to obtain the value `link` takes.

```blorp
---
A module whose every import has an outcome. `import_outcomes` holds one
outcome per import of `parsed` (an accepted module's `imports`, or a rejected
module's kept imports), in import order: it is built by mapping over that
list, so the counts agree by construction.
---
record VisitedModule {
	module: ModuleId,
	source: ModuleSource,
	parsed: ParsedSource,
	import_outcomes: List[ImportOutcome]
}


---
Where a module came from, as the walk found it. `path` is its canonical path,
stored here and nowhere else.
---
record ModuleSource {
	path: String,
	origin: ModuleOrigin,
	reach: ModuleReach,
	text: String
}


---
What the walk hands to `link`: every module it loaded, each visited, in id
order, with the roots' and implicit requests' outcomes and the packages the
modules belong to. Only the walk's final step makes one.
---
opaque type CompletedWalk = WalkResult

private record WalkResult {
	modules: List[VisitedModule],
	roots: List[RootRequestOutcome],
	implicit: List[ImplicitRequestOutcome],
	packages: List[Package]
}
```

### 2.3 `parse_module`

```blorp
---
Lexes and parses one module. Pure: the same id and text give the same result,
whatever was parsed before, so modules can be parsed in any order or at once.
`module` is needed because every span and id this parse issues carries it.
---
pure func parse_module(module: ModuleId, text: String) -> ParsedSource:
	lexed: LexedModule = lex_module(module, text)
	lexed.parse_lexed_module()


---
The parse of one module: its line starts (which every rendered location
needs), its spellings, and either its syntax or the diagnostics that reject
it.
---
record ParsedSource {
	line_starts: List[Int],
	spellings: Spellings,
	outcome: SourceOutcome
}


union SourceOutcome:
	AcceptedSource(ModuleSyntax)
	RejectedSource(RejectedSyntax)
```

A rejected module is specified exactly:

```blorp
---
A module the lexer or parser reported at least one diagnostic in. It has no
tree.

`diagnostics` is every diagnostic the module's lexing and parsing reported,
in the order reported today: the lexer's, then the parser's, with an
interpolation hole's lexer diagnostics where the parser reaches the hole.

`kept_imports` is each `Import` (one module path with its alias and selected
items) during whose parse no diagnostic was reported: the diagnostics count
was the same after its last token as before its first. An import that
reported anything is dropped whole, items included. So is everything that is
not an import. The walk resolves the kept imports and loads their modules, so
those modules' own problems are reported in the same run, as they are today.
---
record RejectedSyntax {
	diagnostics: AtLeastOne[SyntaxDiagnosticAt],
	kept_imports: List[Import]
}
```

The lexer runs first over the whole text. The parser then runs over its
tokens, so the diagnostics list is in today's order.

```blorp
---
The lexer's product for one module: its tokens, its interned spellings, its
checked literal values, the pieces of each interpolated string, its line
starts and its lexer diagnostics. Read only by the parser.
---
record LexedModule {
	module: ModuleId,
	source: LexedSource,
	tokens: List[Token],
	spellings: Spellings,
	line_starts: List[Int],
	diagnostics: List[SyntaxDiagnosticAt]
}


---
What the parser reads but never changes: the text (for hole lexing), the
literal values (by literal token), and the pieces of each interpolated string.
---
record LexedSource {
	text: String,
	literals: List[LiteralValue],
	interpolations: List[InterpolationScan]
}


---
The checked value of one literal token (section 5.2).
---
union LiteralValue:
	IntegerValue(Int128)
	FloatValue(DecimalFloat)
	TextValue(String)      -- a string literal's or docstring's decoded text


pure func lex_module(module: ModuleId, text: String) -> LexedModule
```

`Token` uses `fixed record` provisionally:

```blorp
fixed record Token {
	kind: TokenKind,
	span: Span,
	payload: Int
}
```

It is a hot, scalar-only transient value in token lists, not part of the tree
or the public product model. An ordinary `record`
would change its storage cost; M2 measures that choice against the token
parity and cost gates before retaining the fixed layout. It is private to
`lex/` and the parser's cursor module, and is read only through
accessors that check the kind:

```blorp
pure func token_spelling(token: Token) -> Option[SpellingId]
pure func token_literal(token: Token) -> Option[LiteralIndex]
pure func token_codepoint(token: Token) -> Option[Char]
pure func token_interpolation(token: Token) -> Option[InterpolationIndex]
```

The spelling is a transition, not a permanent layout promise: when the
record simplification sequence converges old value records, remeasure tokens
and choose a stage-local storage representation if ordinary records miss the
same cost gate.

The payload `Int` whose meaning depends on the kind is the one tagged `Int`
left in the stage. It is confined to two modules and never reaches the output.
It goes when the token's storage can hold a value union at an acceptable
measured cost; the record simplification plan does not itself supply that
layout optimization.

`LiteralIndex` and `InterpolationIndex` are opaque indexes into
`LexedSource`, minted only by the lexer.

An interpolated string's pieces are scanned once by the lexer:

```blorp
union ScannedPiece:
	ScannedText(String)
	ScannedHole(HoleScan)


---
A hole's bytes, `${` through `}`; its expression is `expression_start ..
expression_end`.
---
record HoleScan {
	expression_start: Int,
	expression_end: Int,
	span: Span
}


record InterpolationScan {
	pieces: List[ScannedPiece]
}
```

When the parser reaches a hole, it lexes the hole's bytes into a token list of
its own (`lex_hole`) and parses one expression from a cursor over that list.
The outer cursor is an ordinary value held across the call. Nothing is
appended after the module's end-of-file token, and no cursor is moved by hand.

### 2.4 Diagnostics, and what stops compilation

Each kind of diagnostic lives in the outcome it explains:

| Diagnostic | Lives in | Stops compilation |
| --- | --- | --- |
| Lexer and parser diagnostics | `RejectedSyntax.diagnostics` | Yes |
| A root that loads nothing | `RootOutcome.RootRejected(RootDiagnostic)` | Yes |
| A missing implicit module | `ImplicitOutcome.ImplicitRejected(ImplicitDiagnostic)` | Yes |
| An import that names no module | `ImportOutcome.ImportNotFound` | No; later stages report it in their own words, as today |
| An import whose file differs in letter case, or cannot be read, verified or admitted | `ImportOutcome.ImportRejected(ImportFailure)` | Yes |

`link` produces a program only when nothing stops compilation. Otherwise it
produces a `DiscoveryFailure`: every stopping problem in report order, with
the sources their spans point into. The order is roots, then implicit
modules, then each module's syntax diagnostics in module order, then import
failures in import order, which is today's report order.

Which import failures stop compilation is decided in
`discovery_front_end.brp` today (`resolution_diagnostic_stops_discovery`).
Here it is a type: `ImportNotFound` becomes a program's `ImportUnresolved`
target, and `ImportRejected` becomes a problem.

Syntax diagnostics keep today's typed union, with two argument types
changed:

- A name argument (`ReservedKeywordAsName`, `UnknownAnnotation`, the
  concurrency parameter codes) becomes a `SpellingId` of its module.
- `IntegerLiteralOverflow` carries the written digits as a `String`.

The import diagnostics drop their `ImportId` argument, because the failure is
held by the import's own outcome.

```blorp
---
A lexer or parser diagnostic at a span of its module.
---
record SyntaxDiagnosticAt {
	span: Span,
	diagnostic: SyntaxDiagnostic
}


---
What resolving one import came to, as the walk records it: a module (loaded
now or before), no module, or a module whose source could not be used.
---
union ImportOutcome:
	ImportReached(ModuleId)
	ImportNotFound
	ImportRejected(ImportFailure)


---
Why an import's source could not be used. Each of these stops compilation.
---
union ImportFailure:
	ImportCaseMismatch(String)      -- the file's stored spelling
	ImportUnverifiableSpelling
	ImportUnreadableSource
	ImportSourceTooLarge(Int)       -- the byte length, since no record holds the source
	ImportTooManySources


---
What resolving a root or an implicit request came to. `RootOutcome` and
`ImplicitOutcome` are today's unions (`RootLoaded(ModuleId)` or
`RootRejected(RootDiagnostic)`, and the implicit pair), unchanged;
`RootCaseMismatch` carries the stored spelling as a `String`.
---
record RootRequestOutcome {
	path: String,
	outcome: RootOutcome
}


record ImplicitRequestOutcome {
	name: String,
	outcome: ImplicitOutcome
}
```

### 2.5 Deterministic order

| What | Order |
| --- | --- |
| `ModuleId` | Load order: roots, implicit modules, then imports breadth first. Every module id is unchanged from today. |
| `SpellingId` | First occurrence within the module: the lexer's scan, then interpolation holes in the order the parser reaches them (as today) |
| `NameId` | Link interns each module's spellings in module order, then spelling order. Apart from the seeded block, which moves to the adapter, this is today's name order. |
| `NameUseId`, `BinderId`, `TypeBinderId` | Source order within the module: minted when the name's token is consumed |
| `ExpressionId`, `PatternId`, `WrittenTypeId`, `DimensionId`, `StatementId`, `BlockId` | Completion order within the module (post-order). Within a family, a subtree's ids form one contiguous range ending at its root. That is the property today's node table has (resolution's R0 `SubtreeNotContiguous`). |
| `DefinitionId` | Completion order within the module: a record's fields before the record, a local function before the function that holds it |
| `ImportId` | Source order within the module |

Ids are stable within one compilation and deterministic for the same inputs.
They are never compared across compilations or stored outside the one that
issued them.

### 2.6 Parallel parsing, later

`parse_module` is a pure function of `(ModuleId, String)`, and the walk
assigns a module's id before parsing it. Parallelism therefore needs no
change to any type:

1. A module's id is fixed when its request resolves: the next index, in
   queue order. That is deterministic because requests are resolved in a
   fixed order.
2. The walk can resolve the requests of one breadth-first level, read the
   files, assign ids in order, then parse the level's sources concurrently
   (`List.concurrent` or a `concurrent:` block). The parses share nothing.
3. The results are gathered in id order. Each module's imports then form the
   next level.

Ids, spellings and names come out identical to the sequential walk, because
nothing a parse issues depends on another parse.

Two prerequisites, both outside this design:

- **Fiber overhead.** The task-fiber overhead measured in 2026-09 makes a
  parse about 3 times slower per file on a task (cleanup-stack scan, yield
  migration). It must be fixed in the runtime first.
- **Concurrent reads.** File reads stay in the walk and would need a
  concurrent provider call.

## 3. The syntax types

The types live in `stage_01_discovery/syntax/`. They are the stage's output
types, read by every later stage and built only by `parse/` (and tests).

| File | Holds |
| --- | --- |
| `ids.brp` | The id types and `SpellingId`, their readers, the packing constants, and `IdMint` with every `minted_*` function (section 3.15) |
| `sequences.brp` | `SmallTuple`, `AtLeastOne`, `AtLeastTwo` (section 3.1) |
| `names.brp` | `WrittenName`, `NameUse`, `Binder`, `TypeBinder`, `BindingTarget` (section 3.2) |
| `checked_values.brp` | The checked literal and count values and their only constructors: `DecimalFloat` (`decimal_float`), `PositiveCount` (`positive_count`), `ParentSteps` (`parent_steps`) (sections 3.5, 3.13, 5.2) |
| `module_syntax.brp` | `ModuleSyntax`, `SyntaxCounts`, `ModuleItem`, `Documentation` (section 3.4) |
| `imports.brp` | `ImportBlock`, `Import`, `ModulePath`, `PathAnchor`, `ImportItem` (section 3.5) |
| `foreign.brp` | `ForeignBlock`, `ForeignArgument`, `ForeignFunction`, `ForeignCName` (section 3.6) |
| `declarations.brp` | Every declaration record, `Function`, `Signature`, `Annotation`, and the parameter, type-parameter, trait-reference and constraint records (sections 3.7, 3.8) |
| `definitions.brp` | `Definition`, the definitions index's union (section 3.18) |
| `types.brp` | `WrittenType`, `TypeArgument`, `BoundedTypeArgument` (receivers only), `Dimension` and their kinds (section 3.9) |
| `patterns.brp` | `Pattern`, `PatternKind`, `ListSpread`, `Sign`, `StringForm` (section 3.10) |
| `expressions.brp` | `Expression`, `Statement`, `Block`, `Body` and every form of sections 3.11 to 3.13, including `SubscriptPlace`: bodies, statements and expressions refer to each other, so they share a module, as the body parser does today |
| `dump.brp` | The canonical text form of a module's syntax, for tests and the differential |

The constructors in `checked_values.brp` validate their input and return
`Option`, so a value of these types is always a checked one. They follow the
same import rule as `IdMint` (section 3.15): only `lex/`, `parse/` and tests
may import them; anyone may import the types and their readers.

### 3.1 Bounded sequences

Today the parser enforces some sequence bounds and the types do not state
them: a tuple has 2 to 4 items, an or-pattern at least two alternatives, a
subscript at least one index. Here each bound the parser enforces is a shape,
so a reader never meets the out-of-bound case:

```blorp
---
Two to four items: a tuple's elements, items, element types, or the names
of a tuple binder or tuple destructuring.
---
union SmallTuple[T]:
	Pair(T, T)
	Triple(T, T, T)
	Quadruple(T, T, T, T)


---
At least one item.
---
record AtLeastOne[T] {
	first: T,
	rest: List[T]
}


---
At least two items.
---
record AtLeastTwo[T] {
	first: T,
	second: T,
	rest: List[T]
}
```

One bound stays a parser rule rather than a shape: a variant's payload has at
most `MAX_UNION_VARIANT_FIELDS` (64) types. A 65-arity shape is not
proportionate. The parser reports the 65th field, a fixture pins it, and
section 4.6 does not claim it.

### 3.2 Spans, spellings and names

`Span` keeps today's packing (`tables/span.brp`): source index, start offset
and length in one `Int`. The source index is now the `ModuleId`, since a
module is its source. `NO_SPAN` and `NO_SOURCE` go: with no fallback rows,
nothing needs a span in no source.

```blorp
---
A spelling in its module: the module, and the spelling's index in that
module's spellings. The program-wide `NameId` is `program.name_id(spelling)`.
Packed like every syntax id, so a spelling cannot be read against another
module's table.
---
opaque type SpellingId = Int


---
A name as the source wrote it: which spelling, and where.
---
record WrittenName {
	spelling: SpellingId,
	span: Span
}


---
A name whose meaning a later stage decides, with its own id so that stage
keeps exactly one outcome per use:
- by scope (resolution): a value, a type, a trait, a module qualifier, a
  constructor, a dimension variable, an imported item, a name that either
  binds or refers (an assignment target, a name pattern);
- by type (typecheck), after resolution records that it is not its own: the
  member after a dot, a field name in a record literal or update.
---
record NameUse {
	name: WrittenName,
	use: NameUseId
}


---
A name that introduces a local value: a variable, a parameter, a loop
variable, a lambda parameter, a `with`, `select` or `on` binder, a
destructured name, a list spread.
---
record Binder {
	name: WrittenName,
	binder: BinderId
}


---
A name that introduces a type or dimension parameter of a declaration.
---
record TypeBinder {
	name: WrittenName,
	binder: TypeBinderId
}


---
A binding position that may discard: a name, or `_`.
---
union BindingTarget:
	BindsName(Binder)
	DiscardsValue(Span)
```

**Why a name is a spelling id plus a span, wrapped by role.**

- **Spelling id, not string.** A `String` would allocate per occurrence, or
  share a string object per spelling and still compare by content. Worse, it
  would make the spelling the key, and two different meanings can share a
  spelling. A per-module `SpellingId` costs one `Int`. It compares in O(1)
  within the module, and one indexed read turns it into the program-wide
  `NameId` (section 5).
- **Not the global `NameId` itself.** That would need one shared interner
  during the parse, which would make each module's parse depend on every
  module parsed before it. That rules out parallel parsing, and a module's
  parse could not be tested alone.
- **Not a span alone.** Reading the spelling back from the source would mean
  hashing a slice again at every lookup, which is the interning work done
  over again.
- **The span** is the name's own extent. Diagnostics point at the name, not
  at the node around it. Today that needs `NodeNameSpanRow` (162,465 rows on
  the self-compile); here it is a field.
- **The role wrapper** puts resolution's per-kind schema (`name_role` in the
  resolution design) into the type:
  - a `NameUse` gets exactly one outcome;
  - a `Binder` declares;
  - a `WrittenName` is nobody's to decide.

  Record-field names are `NameUse`s, for the same reason
  as `x.f`: typecheck decides them by type, and its choice of parameter or
  field is keyed by the use's id (section 9, D3).

Declared names (functions, types, fields, variants, globals) are
`WrittenName`s. The declaration's `DefinitionId` is its identity.

### 3.3 Ids

```blorp
---
How a syntax id is laid out: the module in the high bits, the index within the
module's family in the low bits. 15 bits of module match the span's source
limit (`SPAN_SOURCE_LIMIT`); 48 bits of index are far beyond any module.
---
SYNTAX_ID_MODULE_BITS: Int = 15

SYNTAX_ID_INDEX_BITS: Int = 48


opaque type DefinitionId = Int
opaque type ImportId = Int
opaque type StatementId = Int
opaque type BlockId = Int
opaque type ExpressionId = Int
opaque type PatternId = Int
opaque type WrittenTypeId = Int
opaque type DimensionId = Int
opaque type NameUseId = Int
opaque type BinderId = Int
opaque type TypeBinderId = Int


---
An id's module and its index within the module: one pair of readers per id
type. The only constructors are inside `IdMint` (section 3.15).
---
pure func expression_module(id: ExpressionId) -> ModuleId
pure func expression_local_index(id: ExpressionId) -> Int
```

`ModuleId`, `NameId` and `PackageId` stay plain opaque `Int`s:

- a module is its index in the program;
- a name is its index in the program's name table;
- a package is its index in the program's packages.

**The id rule, as a list.** Every construct a later stage elaborates or keys
a fact on carries an id of its family. The list is complete: a construct not
on it carries no id.

| Construct | Id | Field | Keys, in a later stage |
| --- | --- | --- | --- |
| Every declaration, member, method, foreign function and local function | `DefinitionId` | `id` | Referents, signatures, dependency edges, Core functions |
| An import | `ImportId` | `Import.id` | Import target; module alias binding |
| A statement | `StatementId` | `Statement.id` | Statement-level facts: a binding's form, the drop set at its end, a `?=` early exit, a compound assignment's operator impl, a `for` loop's iterator protocol, a concurrent task (resolution's `CaptureRow.closure`) |
| A block | `BlockId` | `Block.id` | Its scope; a `for ... concurrently` body as a closure (`CaptureRow.closure`); the block's value type |
| An expression | `ExpressionId` | `Expression.id` | Inferred type, selected impl, Core node identity |
| The `if` of an `else if` | `ExpressionId` | `ElseIfExpression.id` | Its type, like any `if`: an expression without the `Expression` wrapper |
| An interpolation hole | `ExpressionId` | `Hole.id` | The implicit conversion of its value to text: the impl typecheck selects, and the call Core emits |
| The written place `xs[i]` of `xs[i] = v` | `ExpressionId` | `SubscriptPlace.id` | The element place typecheck types |
| A pattern | `PatternId` | `Pattern.id` | Scrutinee type and exhaustiveness facts |
| A written type | `WrittenTypeId` | `WrittenType.id` | Resolved type |
| A dimension | `DimensionId` | `Dimension.id` | Solved dimension term |
| A name use | `NameUseId` | `NameUse.use` | Resolution outcome, or typecheck's member, parameter or field choice |
| A local binder | `BinderId` | `Binder.binder` | Local binding identity, capture rows |
| A declared type parameter | `TypeBinderId` | `TypeBinder.binder` | Declared type parameter identity |

The else-if, hole and place rows are applications of the rule, not
exceptions. Each is a construct typecheck types without the `Expression`
wrapper, so each carries an `ExpressionId`.

Today's `RootId`, `ImplicitRequestId`, `SourceId`, `PathId`, `NodeId`,
`ParameterId`, `BoundId`, `SupertraitId`, `ImportItemId`, `ForeignBlockId`,
`LiteralId` and `DiagnosticId` go:

- **`NodeId`** splits into the node families above.
- **Parameters** are identified by their binders, and their place in the
  signature is their ordinal.
- **Bounds, supertraits, import items and item variants** are `NameUse`s.
- **Foreign blocks** hold their functions.
- **Literals and paths** are values.
- **Diagnostics** are values in their outcome.
- **Requests** are list positions, read only for rendering.

### 3.4 Modules

```blorp
---
The syntax of one accepted module. `items` is the module in source order: the
tree. `definitions` and `imports` are indexes built by `IdMint` while the
parser builds the tree, read-only afterwards and derived from it:
`definitions` holds every definition at the index of its `DefinitionId`
(section 3.18), and `imports` every import at the index of its `ImportId`.
`counts` sizes the other id families.
---
record ModuleSyntax {
	documentation: Option[Documentation],
	items: List[ModuleItem],
	definitions: List[Definition],
	imports: List[Import],
	counts: SyntaxCounts
}


---
How many ids of each node, name and binder family the module issued; ids are
`0 ..< count` within the module. Definitions and imports are counted by their
indexes' lengths, not here, so no count can disagree with an index.
---
record SyntaxCounts {
	statements: Int,
	blocks: Int,
	expressions: Int,
	patterns: Int,
	written_types: Int,
	dimensions: Int,
	name_uses: Int,
	binders: Int,
	type_binders: Int
}


---
One top-level item, in source order.
---
union ModuleItem:
	FunctionItem(FunctionDeclaration)
	GlobalItem(GlobalDeclaration)
	RecordItem(RecordDeclaration)
	ValueRecordItem(ValueRecordDeclaration)
	UnionItem(UnionDeclaration)
	EnumItem(EnumDeclaration)
	AliasItem(AliasDeclaration)
	BuiltinTypeItem(BuiltinTypeDeclaration)
	ResourceTypeItem(ResourceTypeDeclaration)
	TraitItem(TraitDeclaration)
	ImplementationItem(ImplementationDeclaration)
	ImportBlockItem(ImportBlock)
	ForeignBlockItem(ForeignBlock)


---
A docstring: its text after the delimiters are removed, and where it was.
---
record Documentation {
	text: String,
	span: Span
}
```

`ModuleSyntax.documentation` is the module docstring, the one directly before
the first `import:` block.

### 3.5 Imports

```blorp
---
One `import:` block.
---
record ImportBlock {
	imports: List[Import],
	span: Span
}


---
One import. `path_span` covers the module path; `span` the path through its
alias and selections.
---
record Import {
	id: ImportId,
	path: ModulePath,
	alias: Option[WrittenName],
	items: List[ImportItem],
	path_span: Span,
	span: Span
}


---
A module path as written. Parts are names (`heap`, `lib`, `source`); the text
`./x`, `../../x/y` or `pkg/x` is built from this, never stored.
---
record ModulePath {
	anchor: PathAnchor,
	parts: AtLeastOne[WrittenName]
}


union PathAnchor:
	BareAnchor                          -- `heap`: the provider decides where it resolves
	SameDirectoryAnchor                 -- `./`
	ParentDirectoryAnchor(ParentSteps)  -- `../`, once per step
	NativePackageAnchor                 -- `pkg/...`


---
How many `../` a relative path climbs: one or more. Made only by
`parent_steps`, which returns `None` for a count below one.
---
opaque type ParentSteps = Int

pure func parent_steps(count: Int) -> Option[ParentSteps]


---
One selected symbol: `name`, `name as alias`, or `Union(Variant, ...)`.
`name` is a use: resolution finds it among the target's members.
---
record ImportItem {
	name: NameUse,
	alias: Option[WrittenName],
	constructors: List[NameUse],
	span: Span
}
```

The module alias of `import heap as H` is a `WrittenName`, not a `Binder`.
It declares a module-level name, which resolution binds by the import's
`ImportId`.

### 3.6 Foreign blocks

```blorp
---
A `foreign:` or `foreign(include: "x.h", ...):` block and its functions.
---
record ForeignBlock {
	arguments: List[ForeignArgument],
	functions: List[ForeignFunction],
	span: Span
}


---
`name: "value"`, such as `include: "x.h"`.
---
record ForeignArgument {
	name: WrittenName,
	value: String,
	span: Span
}


---
A foreign function: always a return type, and the C name when written
(`= "c_name"`).
---
record ForeignFunction {
	id: DefinitionId,
	visibility: Visibility,
	annotations: List[Annotation],
	purity: Purity,
	keyword: Span,
	name: WrittenName,
	parameters: List[Parameter],
	return_type: WrittenType,
	c_name: Option[ForeignCName],
	span: Span
}


record ForeignCName {
	name: String,
	span: Span
}
```

### 3.7 Declarations

One record per class. Two forms share a record only when they have the same
parts: a constant and a mutable global, or an alias and an opaque type. Forms
with different parts get separate records: an ordinary record takes type
parameters, while today's `struct` and `fixed record` declarations do not;
a resource type has a cleanup builtin and a builtin type does not; an `enum`
case has no payload and a `union` variant may. Otherwise one record would
have to allow a combination the grammar forbids. The two old value-record
spellings share one temporary declaration form until the record simplification
sequence removes their distinct semantics. The adapter retains their source
spelling for parity with the old parsed AST.

```blorp
---
`[private] [@annotations] [pure] func name[T](params) -> R where ...: body`
at the top level. `body` is absent for a declaration without one (a forward
declaration). `span` starts at the docstring, annotations or `pure` when
written.
---
record FunctionDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	annotations: List[Annotation],
	function: Function,
	span: Span
}


---
What every function with a body slot has: the top-level function, the
local function and the implementation method.
---
record Function {
	signature: Signature,
	type_parameters: List[TypeParameter],
	constraints: List[DimensionConstraint],
	body: Option[Body]
}


---
A callable's signature. `keyword` is the `func` keyword.
---
record Signature {
	purity: Purity,
	keyword: Span,
	name: WrittenName,
	parameters: List[Parameter],
	return_type: Option[WrittenType]
}


---
A function declared in a body. Its header has no visibility, docstring or
annotations: the statement parser starts at `func` or `pure`.
---
record LocalFunction {
	id: DefinitionId,
	function: Function,
	span: Span
}


---
`name [: T] = value` at the top level, or `var name [: T] = value`.
---
record GlobalDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	form: GlobalForm,
	name: WrittenName,
	declared_type: Option[WrittenType],
	value: Expression,
	span: Span
}


enum GlobalForm:
	ConstantGlobal
	MutableGlobal


record RecordDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	fields: List[FieldDeclaration],
	span: Span
}


record ValueRecordDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	spelling: ValueRecordSpelling,
	name: WrittenName,
	fields: List[FieldDeclaration],
	span: Span
}


enum ValueRecordSpelling:
	StructSpelling
	FixedRecordSpelling


record FieldDeclaration {
	id: DefinitionId,
	name: WrittenName,
	field_type: WrittenType,
	span: Span
}


record UnionDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	variants: List[VariantDeclaration],
	span: Span
}


---
A union variant, with up to `MAX_UNION_VARIANT_FIELDS` payload types (section
3.1). `True` and `False` are variant names too.
---
record VariantDeclaration {
	id: DefinitionId,
	name: WrittenName,
	payload: List[WrittenType],
	span: Span
}


---
`enum Name:` and its cases. The parser rejects parentheses on an enum
case, payload or empty.
---
record EnumDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	cases: List[EnumCase],
	span: Span
}


record EnumCase {
	id: DefinitionId,
	name: WrittenName,
	span: Span
}


---
`type alias Name[T] = Target` and `opaque type Name[T] = Target`.
---
record AliasDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	form: AliasForm,
	name: WrittenName,
	type_parameters: List[TypeParameter],
	target: WrittenType,
	span: Span
}


enum AliasForm:
	TransparentAlias
	OpaqueAlias


---
`type Name[T] = builtin`.
---
record BuiltinTypeDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	span: Span
}


---
`resource type Name[T] = builtin` or `= builtin("cleanup")`.
---
record ResourceTypeDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	cleanup: Option[CleanupBuiltin],
	span: Span
}


record CleanupBuiltin {
	name: String,
	span: Span
}


---
`trait Name[T]: Super + ...:` with methods; either part may be absent.
---
record TraitDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	supertraits: List[TraitReference],
	methods: List[TraitMethod],
	span: Span
}


---
A trait's method: a signature, and a default body when written. A trait
method takes no type parameters and no `where` clause.
---
record TraitMethod {
	id: DefinitionId,
	signature: Signature,
	default_body: Option[Body],
	span: Span
}


---
`implements Trait for Receiver:` and its methods. It has no name of its own:
its identity is its id, and resolution binds no name for it.
---
record ImplementationDeclaration {
	id: DefinitionId,
	visibility: Visibility,
	documentation: Option[Documentation],
	keyword: Span,
	trait: NameUse,
	receiver: WrittenType,
	methods: List[ImplementationMethod],
	span: Span
}


record ImplementationMethod {
	id: DefinitionId,
	annotations: List[Annotation],
	function: Function,
	span: Span
}


---
One `@annotation` of a function, in written order. An unknown annotation
name, or annotations before anything but a function, are reported, so an
accepted module holds only these.
---
record Annotation {
	annotation: FunctionAnnotation,
	span: Span
}


enum FunctionAnnotation:
	TailRecursiveAnnotation
	NoCopyAnnotation
	DebugOnlyAnnotation
	ResourceResultOrdinaryAnnotation
```

`Visibility` (`PublicVisibility`, `PrivateVisibility`) and `Purity`
(`PureFunction`, `ImpureFunction`) are today's enums. Visibility appears only
on records that `private` can precede: top-level declarations and foreign
functions.

### 3.8 Parameters, type parameters, bounds and constraints

```blorp
---
One parameter of a function, method or foreign function. Its place in its
signature's list is its ordinal.
---
record Parameter {
	binding: ParameterBinding,
	declared_type: Option[WrittenType],
	span: Span
}


---
`name`, `_`, or `(a, b)`.
---
union ParameterBinding:
	NamedParameter(Binder)
	WildcardParameter(Span)
	TupleParameter(TupleBinding)


record TupleBinding {
	names: SmallTuple[Binder],
	span: Span
}


---
A declared type parameter: `T` with its bounds, `#N`, or `#_`. The
parser rejects bounds on a dimension parameter.
---
union TypeParameter:
	TypeVariable(TypeVariableParameter)
	DimensionVariable(TypeBinder)       -- `#N`; the binder's spelling is `N`
	WildcardDimensionParameter(Span)    -- `#_`


record TypeVariableParameter {
	binder: TypeBinder,
	bounds: List[TraitReference],
	span: Span
}


---
A trait named in a bound, a supertrait list or a bounded type argument:
`Trait` or `alias.Trait`. `span` covers the qualifier, dot and name.
---
record TraitReference {
	qualifier: Option[NameUse],
	trait: NameUse,
	span: Span
}


---
`where left == right`.
---
record DimensionConstraint {
	left: Dimension,
	right: Dimension,
	span: Span
}
```

Today's `BoundRow`, `BoundQualifierRow`, `SupertraitRow`,
`SupertraitQualifierRow`, `TypeParameterRow` and the inline `TypeBoundNode`
and `QualifiedTypeBoundNode` are all one `TraitReference` here. A bound in a
declaration and a bound inside a written type had two representations
because one was a row and the other a node.

### 3.9 Written types and dimensions

```blorp
record WrittenType {
	id: WrittenTypeId,
	span: Span,
	kind: WrittenTypeKind
}


union WrittenTypeKind:
	NamedType(NameUse, List[TypeArgument])                 -- `Int`, `List[T]`, `Self`
	QualifiedType(NameUse, NameUse, List[TypeArgument])    -- `m.Type[T]`: qualifier, then type
	VoidType                                               -- `()`
	TupleType(SmallTuple[TypeArgument])                    -- `(A, B)`
	FunctionType(Purity, List[TypeArgument], WrittenType)  -- `(A) -> R`, `pure (A) -> R`
	ArrayType(WrittenType, AtLeastOne[Dimension])          -- `Float[#3]`, `Int[#N, #M]`
	RangeType(Dimension)                                   -- `..#N`
	DimensionType(Dimension)                               -- `rows: #N`, `-> #M`: the type of a dimension value


---
One argument in brackets or parentheses: a type, a dimension, or, in an
`implements` receiver only, a bounded type parameter.
---
union TypeArgument:
	TypeArgumentType(WrittenType)
	DimensionArgument(Dimension)
	BoundedArgument(BoundedTypeArgument)


---
`T: Eq + Hash` inside an `implements` receiver's arguments
(`implements Show for Box[T: Eq]`): the type parameter that impl introduces,
with its bounds. A bound written in any other type is a parse error, so
`BoundedArgument` occurs only below an implementation's receiver.
---
record BoundedTypeArgument {
	parameter: NameUse,
	bounds: AtLeastOne[TraitReference],
	span: Span
}


record Dimension {
	id: DimensionId,
	span: Span,
	kind: DimensionKind
}


union DimensionKind:
	NamedDimension(NameUse)                        -- `#N`; the spelling is `N`
	VariadicNamedDimension(NameUse)                -- `#Ds...`
	WildcardDimension                              -- `#_`
	VariadicWildcardDimension                      -- `#_...`
	LiteralDimension(Int128)                       -- `#3`, or `3` inside dimension arithmetic
	DimensionArithmetic(DimensionOperator, Dimension, Dimension)


enum DimensionOperator:
	AddDimensions
	SubtractDimensions
	MultiplyDimensions
	DivideDimensions
```

These keep today's parsing rules, as `type_parser.brp` documents them:

- `Name[#3]`, whose arguments are all dimensions, is the array type
  `ArrayType(NamedType(Name, []), [#3])`.
- `(T)` is `T` itself.
- An array suffix that holds a non-dimension is reported, so in an accepted
  module `ArrayType` holds only dimensions.

`Self` and `void` written as type names are `NamedType` uses of their
spellings. `()` is `VoidType`, where today it is a `NamedTypeNode` spelled
with an invented `Void` name.

A dimension is also a type where a type is required: `rows: #N` and `-> #M`
are documented forms that the standard library uses (the type of a dimension
value, a refinement of `Int`), so `DimensionType(Dimension)` holds one.
Typecheck accepts them; M-1 does not touch them.

A bound inside a type (`x: (T: Eq)`, `List[T: Eq]`) is different: the parser
rejects it everywhere except an `implements` receiver, where the
receiver introduces the impl's type parameters, bare (`Box[T]`) or bounded
(`Box[T: Showable]`, a conditional impl). Type parameters are otherwise only
declared in a bracket list, and the implicit ones are gone: an undeclared `T`
in a signature is an error, not a generalization. So `BoundedArgument` exists
only inside a receiver; typecheck resolves the receiver's bare and bounded
names as the impl's parameters and keeps no discovery elsewhere.

### 3.10 Patterns

```blorp
record Pattern {
	id: PatternId,
	span: Span,
	kind: PatternKind
}


union PatternKind:
	WildcardPattern                                              -- `_`
	NamePattern(NameUse)                                         -- binds, or matches a constructor (resolution decides)
	IntegerPattern(Sign, Int128)                                 -- the magnitude after any `-`
	FloatPattern(Sign, DecimalFloat)
	StringPattern(StringForm, String)                            -- the text after escapes
	CharacterPattern(Char)
	BooleanPattern(Bool)
	ConstructorPattern(NameUse, List[Pattern])                   -- `Some(x)`
	QualifiedConstructorPattern(NameUse, NameUse, List[Pattern]) -- `m.Circle(r)`: qualifier, constructor
	TuplePattern(SmallTuple[Pattern])
	ListPattern(List[Pattern], Option[ListSpread])               -- `[a, b, ...rest]`
	AlternativePatterns(AtLeastTwo[Pattern])                     -- `p | q`


enum Sign:
	NonNegative
	Negative


---
The text form a string literal or pattern was written in. The existing AST
records it, so the formatter can keep it.
---
enum StringForm:
	QuotedString
	RawString
	PipeString
	RawPipeString


---
`...rest` or `..._`. `span` covers the dots and the target.
---
record ListSpread {
	target: BindingTarget,
	span: Span
}
```

### 3.11 Expressions

```blorp
record Expression {
	id: ExpressionId,
	span: Span,
	kind: ExpressionKind
}


union ExpressionKind:
	-- Names and literals (literal values are checked: section 5.2).
	NameReference(NameUse)
	IntegerLiteral(Int128)                               -- the magnitude; a `-` is a `Unary`
	FloatLiteral(DecimalFloat)
	StringLiteral(StringForm, String)                    -- the text after escapes; joined lines for a pipe string
	InterpolatedString(InterpolationForm, List[InterpolationPiece])
	BooleanLiteral(Bool)
	CharacterLiteral(Char)
	VoidValue                                            -- `void`, `()`, or `_` as an expression
	CompilerBuiltin(Option[String])                      -- `builtin` or `builtin("name")`
	-- Operators.
	Unary(UnaryOperator, Expression)
	Binary(BinaryOperator, Expression, Expression)
	ShortCircuit(LogicalOperator, Expression, Expression)
	RangeExpression(Expression, Expression)
	-- Calls and access.
	Call(Expression, List[Expression])
	FieldAccess(Expression, NameUse)                     -- `x.f`: a field, a method, or a module member
	Subscript(Expression, AtLeastOne[Expression])
	-- Aggregates.
	ListLiteral(List[Expression])
	TupleLiteral(SmallTuple[Expression])
	VectorLiteral(List[Expression])
	RecordLiteral(List[NamedValue])
	RecordUpdate(Expression, List[NamedValue])
	DictLiteral(List[DictEntry])
	OpaqueConversion(OpaqueDirection, WrittenType, Expression)
	-- Control flow.
	If(IfExpression)
	Match(Expression, List[MatchCase])
	Select(List[SelectArm])
	With(WithExpression)
	DebugBlock(Block)
	Lambda(LambdaExpression)
	ConcurrentBlock(ConcurrentBlockExpression)
	Detach(Expression)
	Break
	Continue


enum UnaryOperator:
	Negate
	LogicalNot


enum BinaryOperator:
	Add
	Subtract
	Multiply
	Divide
	Modulo
	Equal
	NotEqual
	Less
	LessEqual
	Greater
	GreaterEqual


---
`and` and `or`: they may skip their right operand, so they are not operators
over two evaluated values.
---
enum LogicalOperator:
	LogicalAnd
	LogicalOr


enum OpaqueDirection:
	IntoOpaque
	FromOpaque


---
`name = value` in a record literal or a record update. `name` is a use that
typecheck decides against the record type's fields. A call takes only
positional arguments: the language has no named arguments.
---
record NamedValue {
	name: NameUse,
	value: Expression,
	span: Span
}


---
`key => value` in a dict literal.
---
record DictEntry {
	key: Expression,
	value: Expression,
	span: Span
}
```

**`=` in expressions.** Assignment is a statement only. The grammar has no
`=` at an expression position, so `xs = [a = 1]`, `print(ys[0] = 3)` and
`if a = 1:` are parse errors in both parsers, and `f(name = value)` is the
same error because there are no named arguments. `Expression` therefore has
no assignment form. A record field `name = value` is recognized by the
two-token lookahead `name =` before anything is built.

**Grouping parentheses.** These add no node. They widen the enclosed
expression's span to the delimiters, except for a name and a lambda, whose
span stays token-exact, as today (`keeps_token_span`). The expression keeps
its id.

### 3.12 Statements, blocks and bodies

```blorp
record Statement {
	id: StatementId,
	span: Span,
	kind: StatementKind
}


union StatementKind:
	ExpressionStatement(Expression)
	VariableDeclaration(VariableStatement)       -- `var x [: T] = v`
	TypedBinding(TypedBindingStatement)          -- `x: T = v`
	Assignment(AssignmentStatement)              -- `x = v`: declares or assigns (resolution decides)
	QuestionBinding(QuestionBindingStatement)    -- `x [: T] ?= v`
	CompoundAssignment(CompoundAssignmentStatement)
	SubscriptAssignment(SubscriptAssignmentStatement)
	TupleDestructure(TupleDestructureStatement)
	WhileLoop(WhileStatement)
	ForLoop(ForStatement)
	ConcurrentForLoop(ConcurrentForStatement)
	LocalFunctionStatement(LocalFunction)


---
An indented block. It always has a last statement, which gives the block its
value; an empty block is reported, so an accepted module has none.
---
record Block {
	id: BlockId,
	leading: List[Statement],
	last: Statement,
	span: Span
}


---
The body of a function, a method or a lambda: an indented block, or an
expression on the `:` line.
---
union Body:
	BlockBody(Block)
	ExpressionBody(Expression)


record VariableStatement {
	target: BindingTarget,
	declared_type: Option[WrittenType],
	value: Expression
}


record TypedBindingStatement {
	target: BindingTarget,
	declared_type: WrittenType,
	value: Expression
}


---
`x = v` or `_ = v`. A name target either declares a new binding or assigns an
existing mutable one; resolution decides by a lookup (resolution design
section 2.9), so the target is a use, not a binder.
---
record AssignmentStatement {
	target: AssignmentTarget,
	value: Expression
}


union AssignmentTarget:
	AssignsName(NameUse)
	AssignsDiscard(Span)


record QuestionBindingStatement {
	binder: Binder,
	declared_type: Option[WrittenType],
	value: Expression
}


---
`x += v` and its siblings. `_ += v` is rejected, so the target is
always a name.
---
record CompoundAssignmentStatement {
	target: NameUse,
	operator: CompoundOperator,
	value: Expression
}


enum CompoundOperator:
	AddAssign
	SubtractAssign
	MultiplyAssign
	DivideAssign


---
`xs[i] = v`: the written place and the value stored there.
---
record SubscriptAssignmentStatement {
	place: SubscriptPlace,
	value: Expression
}


---
The written `xs[i]` of `xs[i] = v`: the element place typecheck types, so it
carries an `ExpressionId` (section 3.3). Minted when the parser sees the `=`,
before the value is parsed.
---
record SubscriptPlace {
	id: ExpressionId,
	span: Span,
	collection: Expression,
	indices: AtLeastOne[Expression]
}


---
`(a, _, c) = v`.
---
record TupleDestructureStatement {
	targets: SmallTuple[BindingTarget],
	value: Expression
}


record WhileStatement {
	condition: Expression,
	body: Block
}


record ForStatement {
	binder: LoopBinder,
	iterable: Expression,
	body: Block
}


union LoopBinder:
	LoopVariable(BindingTarget)                  -- `for x in`, `for _ in`
	LoopTuple(SmallTuple[BindingTarget], Span)   -- `for (k, v) in`
```

A `var`, typed or `?=` value written on the next line, indented, is still an
expression. The parser reads it with the layout rule for indented values;
it is not a block. A statement's span is in its `Statement` wrapper, so the
statement records do not repeat it.

**Statements and expressions.** The current parser accepts `if`, `match`,
`select`, `with`, `debug:`, `concurrent:` and lambdas as expressions,
anywhere a primary expression may stand. It accepts `var`, bindings,
destructuring, `while`, `for` and local functions only as statements. The
split above follows that. Assignment is a statement only.

### 3.13 Control flow, interpolation and concurrency

```blorp
record IfExpression {
	condition: Expression,
	then_block: Block,
	else_branch: Option[ElseBranch]
}


---
`else:` or `else if`. `keyword` is the `else` keyword, which neither branch's
span covers; the formatter places comments around it.
---
record ElseBranch {
	keyword: Span,
	body: ElseBody
}


union ElseBody:
	ElseBlock(Block)
	ElseIf(ElseIfExpression)


---
The `if` of an `else if`: an expression of its own (section 3.3).
---
record ElseIfExpression {
	id: ExpressionId,
	span: Span,
	conditional: IfExpression
}


---
`pattern: body`. A case written on the pattern's line is one statement.
---
record MatchCase {
	pattern: Pattern,
	body: CaseBody,
	span: Span
}


union CaseBody:
	CaseBlock(Block)
	CaseStatement(Statement)


record SelectArm {
	kind: SelectArmKind,
	body: Block,
	span: Span
}


union SelectArmKind:
	ReceiveArm(BindingTarget, Expression)   -- `x from channel:`
	SealedArm(Expression)                   -- `sealed channel:`
	AfterArm(Expression)                    -- `_ after timeout:`


record WithExpression {
	acquisition: WithAcquisition,
	body: Block
}


union WithAcquisition:
	WithValue(WithBinding)                  -- `with r [: T] = v:`
	WithTry(WithTryBinding)                 -- `with r [: T] ?= v [on e => mapped]:`


record WithBinding {
	target: BindingTarget,
	declared_type: Option[WrittenType],
	value: Expression,
	span: Span
}


record WithTryBinding {
	target: BindingTarget,
	declared_type: Option[WrittenType],
	value: Expression,
	on_error: Option[ErrorMap],
	span: Span
}


---
`on e => mapped`.
---
record ErrorMap {
	target: BindingTarget,
	value: Expression,
	span: Span
}


record LambdaExpression {
	purity: Purity,
	parameters: List[LambdaParameter],
	return_type: Option[WrittenType],
	body: Body
}


record LambdaParameter {
	target: BindingTarget,
	declared_type: Option[WrittenType],
	span: Span
}


enum InterpolationForm:
	QuotedInterpolation
	PipeInterpolation


---
Text pieces and holes in source order; a text piece is present before,
between and after holes when it is non-empty.
---
union InterpolationPiece:
	InterpolationText(String)
	InterpolationHole(Hole)


---
`${value}`. `span` covers the `$` through the `}`. `id` is the hole's own
expression id: the implicit conversion of `value` to text, which typecheck
selects and Core emits (section 3.3).
---
record Hole {
	id: ExpressionId,
	value: Expression,
	span: Span
}


---
`concurrent:` or `concurrent(max_threads: n, timeout: t):`. Each task is a
statement of `body`, identified by its `StatementId`.
---
record ConcurrentBlockExpression {
	max_threads: Option[CountParameter],
	timeout: Option[TimeoutParameter],
	body: Block
}


---
`for x in xs concurrently(limit: n[, timeout: t]):`. `limit` is required; the
parser reports a missing one, so an accepted module always has it. The body
runs as a task per element: its `BlockId` identifies that closure.
---
record ConcurrentForStatement {
	binder: Binder,
	iterable: Expression,
	limit: CountParameter,
	timeout: Option[TimeoutParameter],
	body: Block
}


---
`max_threads: n` or `limit: n`: a positive integer literal, checked by the
parser.
---
record CountParameter {
	count: PositiveCount,
	name_span: Span,
	span: Span
}


---
A count of one or more that fits in `Int`. Made only by `positive_count`,
which returns `None` for anything else.
---
opaque type PositiveCount = Int

pure func positive_count(value: Int128) -> Option[PositiveCount]


record TimeoutParameter {
	value: Expression,
	name_span: Span,
	span: Span
}
```

`positive_count` replaces the old `positive_count_of_literal`, which saturated
an over-range literal to `Int`'s maximum. The parser now rejects a count
above `Int`'s range with the same diagnostic as a non-positive one (M-1).

### 3.14 Recursion depth

Left-associative chains are a loop in the parser and a nesting in the tree.
`a + b + c + ...` parses in a precedence-climbing loop, and a method chain
`x.f().g().h()...` parses in a postfix loop. Both produce a left spine as
deep as the chain: a 5,000-term sum is a `Binary` nested 4,999 deep in its
left operand. Today's node table holds the same nesting as child edges, and
the old AST holds it as nesting too, so this is not new. But every walker
over the tree must survive it.

The rule for walkers in discovery, the adapter and later stages: **walk a
left spine with a loop, and recurse only on right operands and arguments.**
For example, collect `Binary` operands down the left spine into a list, then
fold. Do the same for `FieldAccess`, `Call` and `Subscript` receivers and
callees. Recursion depth is then bounded by right-nesting and bracket
nesting, which the source's own structure bounds. The parser already
recurses that deep.

M4's gate adds deep-chain tests, through parse, dump, adapter and the old
typecheck:

- a 5,000-term `+`;
- a 2,000-call method chain;
- a 2,000-deep `else if` chain (an `else if` nests in the else branch);
- a 1,000-deep nested list literal (right-nesting, bounded by brackets).

The current adapter's 6,000-operand chain test is kept.

### 3.15 `IdMint`

Ids are managed exclusively behind one opaque type. `syntax/ids.brp` holds
the id types, their readers, and `IdMint`, the only maker of ids.

```blorp
---
The maker of one module's syntax ids. An id exists only once its node is
being built: every function here mints the next id of a family and builds the
node with it in the same call, so no caller ever holds an id its node does not
carry. Definitions and imports are also indexed here, in that same call, at
the index of their id.
---
opaque type IdMint = MintState

private record MintState {
	module: ModuleId,
	counts: SyntaxCounts,
	definitions: List[Definition],
	imports: List[Import]
}


pure func new_id_mint(module: ModuleId) -> IdMint


---
Builds an expression with the next expression id: `{id, span, kind}`.
---
pure func minted_expression(mint: IdMint, span: Span, kind: ExpressionKind) -> (IdMint, Expression)
pure func minted_statement(mint: IdMint, span: Span, kind: StatementKind) -> (IdMint, Statement)
pure func minted_block(mint: IdMint, leading: List[Statement], last: Statement, span: Span) -> (IdMint, Block)
pure func minted_pattern(mint: IdMint, span: Span, kind: PatternKind) -> (IdMint, Pattern)
pure func minted_written_type(mint: IdMint, span: Span, kind: WrittenTypeKind) -> (IdMint, WrittenType)
pure func minted_dimension(mint: IdMint, span: Span, kind: DimensionKind) -> (IdMint, Dimension)
pure func minted_name_use(mint: IdMint, name: WrittenName) -> (IdMint, NameUse)
pure func minted_binder(mint: IdMint, name: WrittenName) -> (IdMint, Binder)
pure func minted_type_binder(mint: IdMint, name: WrittenName) -> (IdMint, TypeBinder)


---
The three constructs that carry an `ExpressionId` without the `Expression`
wrapper (section 3.3), each built with its id in one call.
---
pure func minted_else_if(mint: IdMint, span: Span, conditional: IfExpression) -> (IdMint, ElseIfExpression)
pure func minted_hole(mint: IdMint, value: Expression, span: Span) -> (IdMint, Hole)
pure func minted_subscript_place(
	mint: IdMint,
	span: Span,
	collection: Expression,
	indices: AtLeastOne[Expression],
) -> (IdMint, SubscriptPlace)


---
Builds an import with the next import id and indexes it.
---
pure func minted_import(
	mint: IdMint,
	path: ModulePath,
	alias: Option[WrittenName],
	items: List[ImportItem],
	path_span: Span,
	span: Span,
) -> (IdMint, Import)


---
What the module issued: the counts and the two indexes, for `ModuleSyntax`.
Consumes the mint.
---
pure func issued(mint: IdMint) -> IssuedIds
```

**Definitions** are minted the same way, one function per class. Each takes
the record's parts, mints the next definition id, builds the record with it,
indexes the record, and returns it:

```blorp
---
Builds a top-level function with the next definition id and indexes it.
---
pure func minted_function(
	mint: IdMint,
	visibility: Visibility,
	documentation: Option[Documentation],
	annotations: List[Annotation],
	function: Function,
	span: Span,
) -> (IdMint, FunctionDeclaration)


pure func minted_field(mint: IdMint, name: WrittenName, field_type: WrittenType, span: Span) -> (IdMint, FieldDeclaration)


---
Builds a record declaration over its already-minted `fields`.
---
pure func minted_record(
	mint: IdMint,
	visibility: Visibility,
	documentation: Option[Documentation],
	name: WrittenName,
	type_parameters: List[TypeParameter],
	fields: List[FieldDeclaration],
	span: Span,
) -> (IdMint, RecordDeclaration)

-- ... one `minted_*` for each class of section 3.18: local function, trait
-- method, implementation method, foreign function, global, value record, union,
-- variant, enum, enum case, alias, builtin type, resource type, trait and
-- implementation.
```

What this guarantees:

- **No id before its node.** The id types are `opaque`, so only `ids.brp` can
  make one. Inside `ids.brp`, every function that makes an id also builds the
  node that carries it and returns the node. No function returns a bare new
  id, so no id is ever predicted.
- **The index position is not a separate fact.** A definition's id is the
  next count of its family. The same call appends the record to the
  definitions index at that position, inside one update of `MintState`.
- **Post-order follows from building.** A record is built after its last
  child, because its parts are arguments. So members are minted before their
  owner and get smaller ids, and a record cannot be built before its fields
  exist.
- **A minted record is never updated afterwards.** No code makes a changed
  copy of a syntax record (`{ declaration | ... }`) once the mint has built
  it, so the definitions and imports indexes can never hold a stale copy of a
  record the tree holds. The parser builds each record once, complete, from
  parts it has finished.

What it does not rule out: **duplicate ids.** Blorp has no linear types. A
parse that kept using an old `IdMint` after handing on a newer one, or that
called `new_id_mint` twice for one module, would mint the same id twice.
Three rules keep that from happening, and the census catches it if they are
broken:

- `new_id_mint` is called once per module, in `parse_lexed_module`;
- an interpolation hole's sub-parse uses the module's mint, threaded through
  the same `ParseState`, never a mint of its own;
- the mint is reachable only through the `finished_*` functions of
  `ParseState` (section 3.16), which hand the updated mint straight back into
  the state they return.

The id census (section 4.6) finds a duplicate or a gap. It runs in debug
builds at link and as a corpus test.

**Who may mint.**

- **Only the parser imports the mint.** `scripts/check-blorp-layout` gains a
  rule: `IdMint`, `new_id_mint`, `issued` and the `minted_*` functions may be
  imported only by `compiler_new/stage_01_discovery/parse/parse_state.brp`
  and by tests. The id types and their readers are importable by anyone. The
  rule checks the names in import lists, a small extension of the existing
  check. The checked-value constructors of `syntax/checked_values.brp`
  (section 3) follow the same rule, for `lex/` and `parse/`.
- **Later stages never construct syntax** (section 1). They cannot make an
  id, so a syntax value they built would have to reuse an id the parser
  issued for another node. The rule says they never build one; code review
  enforces it.

**An M1 prerequisite needs a fresh check.** At M0, a compiler bug blocked
this layout: `syntax/ids.brp` imports the node types it builds (from
`expressions.brp`, `declarations.brp` and the others), and those modules
import the id types from `ids.brp`. An opaque type inside an import cycle is
rejected by that compiler: a record field of the opaque type failed with `Record field
'id': expected d.DId, got DId`. The probe pairs `d.brp`/`e.brp` and `m3.brp`
failed; the same shapes without the cycle (`f.brp`, `g.brp`, `m4.brp`)
passed. M1 first retains and reruns a minimal cycle fixture on its integration
base, then fixes the compiler if it still fails. The design keeps the mint
beside the id types, because that is what makes "only the mint makes an id"
structural. It does not move the node types into `ids.brp` or the mint out
of it to dodge the bug.

**The no-discard rule.** The parser decides by lookahead before it builds,
and never drops a node it built in an accepted parse. Today's parser
discards in two places, and each changes:

1. **`xs[i] = v`.** The parser parses the collection and indices, then looks
   at the next token. On `=` it mints a `SubscriptPlace` from them, parses
   the value, and builds the statement from the place and the value.
   Otherwise it mints the `Subscript` expression. The place is minted before
   the value is parsed, so post-order and contiguity hold, and the id order
   matches today's `SubscriptNode` before its value.
2. **Record literals.** `{x = 1}` is already recognized by lookahead
   (`starts_record_field`).

A placeholder built after a diagnostic may be dropped: its module is
rejected, so no tree holds it (section 3.17).

### 3.16 Parse state and parse function shape

The parse state holds the cursor, the mint, the module's spellings and its
diagnostics, and never leaves `parse_module`. It is opaque, in
`parse/parse_state.brp`, so the rest of `parse/` reaches the mint only
through the `finished_*` functions:

```blorp
---
The state of one module's parse. `parse_lexed_module` builds it from the
`LexedModule`, with the one `IdMint` of the module: the read-only `source`, a
cursor over the tokens, the spellings (which grow when a hole is lexed or a
keyword is read as a name) and the lexer's diagnostics, after which the
parser's own are appended.
---
opaque type ParseState = ParseFields

private record ParseFields {
	source: LexedSource,
	cursor: TokenCursor,
	mint: IdMint,
	spellings: Spellings,
	diagnostics: List[SyntaxDiagnosticAt]
}


---
Whether the statements being parsed are inside a loop: `break`, `continue`
and `?=` placement. A parameter, never saved or restored.
---
enum BodyContext:
	OutsideLoop
	InsideLoop


---
Builds an expression of `kind` at `span` through the mint and returns the
state that holds the advanced mint. Called after the node's children are
parsed, so the children's ids are smaller (post-order). There is one
`finished_*` per `minted_*` of section 3.15: each is the `ParseState` side of
the opaque boundary, the only way the rest of `parse/` reaches the mint.
---
pure func finished_expression(
	state: ParseState,
	span: Span,
	kind: ExpressionKind,
) -> (ParseState, Expression):
	fields: ParseFields = from_opaque ParseState(state)
	(mint, expression) = fields.mint.minted_expression(span, kind)
	(into_opaque ParseState({ fields | mint = mint }), expression)
```

A parse function, in any module of `parse/`:

```blorp
private pure func parse_if(state: ParseState, context: BodyContext) -> (ParseState, Expression):
	keyword: Span = state.current_span()
	(after_condition, condition) = state
		.advanced()
		.parse_expression(context)
	(after_then, then_block) = after_condition
		.expect_colon(ColonInIfCondition)
		.parse_block(context)
	(after_else, else_branch) = after_then.parse_else_branch(context)
	end: Span = match else_branch:
		Some(branch):
			branch.end_span()
		None:
			then_block.span
	after_else.finished_expression(
		keyword.span_covering(end),
		If({condition = condition, then_block = then_block, else_branch = else_branch}),
	)
```

### 3.17 Recovery: a module with a syntax error has no tree

How it works:

- **The parser continues after a diagnostic exactly as today**, so every
  diagnostic of every module is unchanged.
- **Placeholders stay inside the parser.** After an error the parser keeps
  going with a well-formed placeholder in place of what is missing: `void`
  for an expression, `_` for a pattern, `()` for a type, the spelling `_`
  for a name. A placeholder is an ordinary syntax value, made only by the
  `report_*` functions, each of which appends a diagnostic.
- **`parse_lexed_module` returns `AcceptedSource(ModuleSyntax)` only when the
  module has no diagnostic.** Otherwise it returns `RejectedSource` with the
  diagnostics and the kept imports (section 2.3). A placeholder therefore
  never reaches a `ModuleSyntax`, and the tree types need no `Missing*` form
  and no missing name.
- **Discovery reports the diagnostics, and compilation stops** (section 2.4).

What this removes: `MissingExpressionNode`, `MissingPatternNode`,
`MissingTypeNode`, `EMPTY_NAME`, the "parts that did parse" children of a
recovery node, `RecoveryDiagnosticOutsideModule`, and the question of which
later stage handles a recovery node.

What it changes: an import inside a broken import item is no longer
followed. Its module is already rejected, so the only lost diagnostic is a
cascading "unresolved import" for a path that did not parse.

### 3.18 Definitions index

```blorp
---
Every definition of a module, by kind. Each variant holds the same record the
tree holds.
---
union Definition:
	FunctionDefinition(FunctionDeclaration)
	LocalFunctionDefinition(LocalFunction)
	TraitMethodDefinition(TraitMethod)
	ImplementationMethodDefinition(ImplementationMethod)
	ForeignFunctionDefinition(ForeignFunction)
	GlobalDefinition(GlobalDeclaration)
	RecordDefinition(RecordDeclaration)
	ValueRecordDefinition(ValueRecordDeclaration)
	FieldDefinition(FieldDeclaration)
	UnionDefinition(UnionDeclaration)
	VariantDefinition(VariantDeclaration)
	EnumDefinition(EnumDeclaration)
	EnumCaseDefinition(EnumCase)
	AliasDefinition(AliasDeclaration)
	BuiltinTypeDefinition(BuiltinTypeDeclaration)
	ResourceTypeDefinition(ResourceTypeDeclaration)
	TraitDefinition(TraitDeclaration)
	ImplementationDefinition(ImplementationDeclaration)
```

This replaces `DefinitionKind`, `DefinitionRow`, `MemberRow`, `ImplRow`,
`SignatureRow`, `DefinitionTypeRow`, `BodyRow`, `DocumentationRow`,
`AnnotationRow`, `ForeignBindingRow`, `ForeignCNameRow` and
`ResourceCleanupRow`. Each of those facts is a field of the record. A
definition's owner is structural: a field is in its record's `fields`, and a
method in its trait's or implementation's `methods`.

### 3.19 Where every current node kind goes

Every one of today's 128 `NodeKind`s (`tables/row_kinds.brp`) has a home,
or is rejected by the assignment-statement rule or M-1. Counts are from the
self-compile census (Appendix A).

| Today's node kind(s) | Count | New home |
| --- | ---: | --- |
| `IdentifierNode` | 282,208 | `NameReference(NameUse)` |
| `IntegerLiteralNode`, `FloatLiteralNode` | 10,537 | `IntegerLiteral(Int128)`, `FloatLiteral(DecimalFloat)` |
| `StringLiteralNode`, `RawStringLiteralNode`, `PipeStringLiteralNode`, `RawPipeStringLiteralNode` | 24,750 | `StringLiteral(StringForm, String)` |
| `InterpolatedStringNode`, `InterpolatedPipeStringNode` | 922 | `InterpolatedString(InterpolationForm, List[InterpolationPiece])` |
| `InterpolationTextNode` | 2,181 | `InterpolationText(String)` |
| `InterpolationHoleNode` | 1,705 | `InterpolationHole(Hole)` |
| `TrueLiteralNode`, `FalseLiteralNode` | 9,794 | `BooleanLiteral(Bool)` |
| `CharLiteralNode` | 546 | `CharacterLiteral(Char)` |
| `NegateNode`, `NotNode` | 1,999 | `Unary(UnaryOperator, Expression)` |
| `DetachNode` | 5 | `Detach(Expression)` |
| `AddNode` ... `GreaterEqualNode` (11 kinds) | 18,515 | `Binary(BinaryOperator, ...)` |
| `AndNode`, `OrNode` | 6,184 | `ShortCircuit(LogicalOperator, ...)` |
| `RangeNode` | 94 | `RangeExpression(Expression, Expression)` |
| `CallNode` | 97,175 | `Call(Expression, List[Expression])` |
| `FieldAccessNode` | 59,010 | `FieldAccess(Expression, NameUse)` |
| `SubscriptNode` | 724 | `Subscript(Expression, AtLeastOne[Expression])` |
| `ListLiteralNode`, `TupleNode`, `VectorLiteralNode` | 9,915+ | `ListLiteral`, `TupleLiteral(SmallTuple[...])`, `VectorLiteral` |
| `RecordLiteralNode`, `RecordUpdateNode` | 7,514 | `RecordLiteral(List[NamedValue])`, `RecordUpdate(Expression, List[NamedValue])` |
| `RecordFieldNode` | 19,685 | `NamedValue` |
| `DictLiteralNode`, `DictEntryNode` | 114 | `DictLiteral(List[DictEntry])`, `DictEntry` |
| `IntoOpaqueNode`, `FromOpaqueNode` | 1,186 | `OpaqueConversion(OpaqueDirection, WrittenType, Expression)` |
| `BlockNode` | 77,521 | `Block` (in `Body`, `CaseBody`, `ElseBody` and the block fields); never an expression |
| `IfNode` | 10,821 | `If(IfExpression)`; an `else if` is `ElseIf(ElseIfExpression)` |
| `MatchNode`, `MatchCaseNode` | 51,337 | `Match(Expression, List[MatchCase])`, `MatchCase` |
| `SelectNode`, `SelectReceiveArmNode`, `SelectSealedArmNode`, `SelectAfterArmNode` | not in the self-compile | `Select(List[SelectArm])`, `SelectArmKind` |
| `WithNode`, `WithBindingNode`, `WithTryBindingNode`, `WithErrorMapNode` | 42 | `With(WithExpression)`, `WithBinding`, `WithTryBinding`, `ErrorMap` |
| `DebugBlockNode` | 89 | `DebugBlock(Block)` |
| `LambdaNode`, `PureLambdaNode`, `LambdaParameterNode` | 3,927 | `Lambda(LambdaExpression)` with `purity`; `LambdaParameter` |
| `LocalFunctionNode` | (in `LocalFunctionDefinition`) | `LocalFunctionStatement(LocalFunction)`, inline, with its `DefinitionId` |
| `WhileNode` | 698 | `WhileLoop(WhileStatement)` |
| `ForNode`, `LoopBinderNode`, `TupleLoopBinderNode` | 6,135 | `ForLoop(ForStatement)`, `LoopBinder` |
| `ConcurrentForNode`, `ConcurrentBlockNode`, `ConcurrentParameterNode` | not in the self-compile | `ConcurrentForLoop`, `ConcurrentBlock`, `CountParameter` / `TimeoutParameter` |
| `BreakNode`, `ContinueNode` | 884+ | `Break`, `Continue` |
| `VoidNode` | 1,677 | `VoidValue` |
| `BuiltinNode`, `NamedBuiltinNode` | 542+ | `CompilerBuiltin(Option[String])` |
| `MissingExpressionNode`, `MissingPatternNode`, `MissingTypeNode` | 0 in accepted modules | none: a module with a syntax error has no tree (3.17) |
| `VarDeclarationNode` | 6,506 | `VariableDeclaration(VariableStatement)` |
| `TypedBindingNode` | 9,287 | `TypedBinding(TypedBindingStatement)` |
| `AssignmentNode` as a statement | 13,983 | `Assignment(AssignmentStatement)` |
| `AssignmentNode` anywhere else (a list element, a call argument such as `print(ys[0] = 3)`, a condition) | not counted | rejected: assignment is a statement only |
| `QuestionBindNode` | 4,766 | `QuestionBinding(QuestionBindingStatement)` |
| `AddAssignNode` ... `DivideAssignNode` | 1,893 | `CompoundAssignment(...)`; `_ += v` rejected by M-1 |
| `SubscriptAssignmentNode` | 5 | `SubscriptAssignment(SubscriptAssignmentStatement)` |
| `TupleDestructureNode`, `DestructureBinderNode` | 218 | `TupleDestructure(...)`, `BindingTarget` |
| `WildcardPatternNode` | 17,713 | `WildcardPattern` |
| `NamePatternNode` | 53,435 | `NamePattern(NameUse)` |
| `IntegerPatternNode`, `NegativeIntegerPatternNode`, `FloatPatternNode`, `NegativeFloatPatternNode` | 144+ | `IntegerPattern(Sign, Int128)`, `FloatPattern(Sign, DecimalFloat)` |
| `StringPatternNode`, `RawStringPatternNode`, `PipeStringPatternNode`, `RawPipeStringPatternNode` | 1,491+ | `StringPattern(StringForm, String)` |
| `CharPatternNode`, `TruePatternNode`, `FalsePatternNode` | 260 | `CharacterPattern(Char)`, `BooleanPattern(Bool)` |
| `ConstructorPatternNode` | 26,608 | `ConstructorPattern(NameUse, List[Pattern])` |
| `QualifiedConstructorPatternNode`, `PatternQualifierNode` | 412 | `QualifiedConstructorPattern(NameUse, NameUse, List[Pattern])` |
| `TuplePatternNode`, `ListPatternNode` | 1,833 | `TuplePattern(SmallTuple[...])`, `ListPattern` |
| `ListSpreadNameNode`, `ListSpreadWildcardNode` | 187 | `ListSpread` with `BindingTarget` |
| `OrPatternNode` | 781 | `AlternativePatterns(AtLeastTwo[Pattern])` |
| `NamedTypeNode` | 104,774 | `NamedType(NameUse, List[TypeArgument])`; `()` is `VoidType` |
| `QualifiedTypeNode`, `TypeQualifierNode` | 252 | `QualifiedType(NameUse, NameUse, List[TypeArgument])` |
| `BoundedTypeNode` | 54 | `BoundedArgument(BoundedTypeArgument)` inside an `implements` receiver's arguments; rejected by M-1 in every other type |
| `TypeBoundNode`, `QualifiedTypeBoundNode` | 54 | `TraitReference` |
| `DimensionNameTypeNode`, `VariadicDimensionNameTypeNode` | 357 | `NamedDimension(NameUse)`, `VariadicNamedDimension(NameUse)` |
| `DimensionWildcardTypeNode`, `VariadicDimensionWildcardTypeNode` | 8 | `WildcardDimension`, `VariadicWildcardDimension` |
| `DimensionLiteralTypeNode` | 3 | `LiteralDimension(Int128)` |
| `DimensionAddTypeNode` ... `DimensionDivideTypeNode` | 3 | `DimensionArithmetic(DimensionOperator, ...)` |
| A dimension in a type position (`rows: #N`, `-> #M`, `x: #3`) | not counted | `DimensionType(Dimension)` |
| `RangeTypeNode` | 23 | `RangeType(Dimension)` |
| `TupleTypeNode` | 567 | `TupleType(SmallTuple[TypeArgument])` |
| `FunctionTypeNode`, `PureFunctionTypeNode` | 539 | `FunctionType(Purity, List[TypeArgument], WrittenType)` |
| `ArrayTypeNode` | 174 | `ArrayType(WrittenType, AtLeastOne[Dimension])` |

The rows and side tables go as follows:

- `SourceRow`, `ModuleRow` and `ModulePackageRow` become `DiscoveredModule`
  and `ModuleOrigin` (section 4.2).
- `RootRow` and `ImplicitRequestRow` become the program's loaded requests.
- `ImportRow` becomes `Import`.
- `ImportItemRow`, `ImportItemVariantRow` and `ImportItemAliasRow` become
  `ImportItem`.
- `ImportAliasRow` becomes `Import.alias`.
- `ImportTargetRow` becomes the module's import targets.
- `ImportBlockRow` becomes `ImportBlock`.
- `ModuleDocumentationRow` becomes `ModuleSyntax.documentation`.
- `ParameterRow`, `BinderNameRow` and `ParameterTypeRow` become `Parameter`.
- `VariantPayloadRow` becomes `VariantDeclaration.payload`.
- `DimensionConstraintRow` becomes `DimensionConstraint`.
- `ForeignBlockRow` and `ForeignArgumentRow` become `ForeignBlock`.
- `NodeNameSpanRow` becomes the `span` of the `WrittenName` inside the node.
- `ElseKeywordRow` becomes `ElseBranch.keyword`.
- `DimensionNameRow` moves to the adapter.
- `PendingAnnotationRow` and `InterpolationPartRow` become parser locals and
  `ScannedPiece`.
- `SyntaxDiagnosticRow` and `ResolutionDiagnosticRow` become the outcomes in
  section 2.4.

## 4. The output: the contract with later stages

### 4.1 Decision: the trees are the output

The question was whether bodies stay a node table in the output, or the typed
trees are the output. **The trees are the output, held by the module records
that the link step builds.** There is no flatten step.

1. **Every consumer walks.**
   - Resolution walks bodies in scope order. Its design already needed an
     explicit step stack and `child_at(row, n)` per kind.
   - Typecheck walks bodies in evaluation order, and Core lowering walks
     them again.
   - The legacy adapter rebuilds a tree from the table with 25 derived owner
     indexes.

   A node table serves a reader that scans all rows without structure. None
   of discovery's readers is that reader.
2. **Facts are keyed by id, not stored in nodes.** Later stages write their
   facts into their own columns, keyed by the ids discovery stamped.
   Discovery's output stays immutable and shared, and no stage copies it.
   OCaml's `Typedtree` copies the tree per phase; this design does not.
   This is the half of "tables" that pays: columns keyed by identity.
3. **The illegal states are in the readers too.** `NodeArityMismatch`,
   `PayloadOutOfRange` and "child 2 when written" are checks every reader of
   a node table depends on. A typed tree cannot express them.
4. **A flat table could still be derived.** If a measured workload ever needs
   flat rows (a whole-program scan), one walk can build them from the trees,
   documented as derived. Nothing here prevents that, and nothing needs it
   now.

### 4.2 The output types

The simplest shape that states the outcome: a program when nothing stops
compilation, and a report otherwise.

```blorp
union DiscoveryOutcome:
	Discovered(DiscoveredProgram)
	DiscoveryFailed(DiscoveryFailure)


---
A program a later stage may read: every module parsed without a diagnostic,
every root and implicit module loaded, and no import whose source could not
be used. Only `link` makes one.
---
opaque type DiscoveredProgram = ProgramTables

private record ProgramTables {
	modules: List[DiscoveredModule],
	names: NameTable,
	packages: List[Package],
	roots: List[LoadedRequest],
	implicit: List[LoadedRequest]
}


---
One module; its `ModuleId` is its position in the program's `modules`.
`import_targets` holds one target per import of `syntax`, by local import
index. `name_ids` maps each of its spellings to the program-wide name, by
spelling index; it is built by mapping over the module's spellings, so it
covers every spelling the syntax holds. `bases` is where each of its id
families starts in the program-wide numbering (section 4.4), derived at link
from the counts of the modules before it.
---
record DiscoveredModule {
	source: ModuleSource,
	line_starts: List[Int],
	syntax: ModuleSyntax,
	import_targets: List[ImportTarget],
	name_ids: List[NameId],
	bases: SyntaxBases
}


---
An import's target in a discovered program: a module, or none. A missing
module does not stop compilation; resolution reports it where the import's
names are used.
---
union ImportTarget:
	ImportLoaded(ModuleId)
	ImportUnresolved


---
A root or implicit request of a discovered program: always loaded.
---
record LoadedRequest {
	request: String,
	module: ModuleId
}


---
Where a module came from. A package module carries its package.
---
union ModuleOrigin:
	StandardLibraryModule
	UserModule
	NativePackageModule(PackageId)
	SourcePackageModule(PackageId)


enum ModuleReach:
	RootModule
	ImplicitModule
	ImportedModule


record Package {
	name: String,
	kind: PackageKind
}


---
The first program-wide index of each family in one module: the prefix sums
of the modules' counts, in module order.
---
record SyntaxBases {
	definitions: Int,
	imports: Int,
	statements: Int,
	blocks: Int,
	expressions: Int,
	patterns: Int,
	written_types: Int,
	dimensions: Int,
	name_uses: Int,
	binders: Int,
	type_binders: Int
}
```

The failure side holds what rendering needs and nothing else:

```blorp
---
Why discovery did not produce a program: each problem, in report order, and
the sources their spans point into.
---
record DiscoveryFailure {
	sources: List[FailedSource],
	problems: AtLeastOne[DiscoveryProblem]
}


---
A loaded module, as rendering needs it. `spellings` is there because a
syntax diagnostic's name argument is a spelling of its module.
---
record FailedSource {
	source: ModuleSource,
	line_starts: List[Int],
	spellings: Spellings
}


union DiscoveryProblem:
	RootProblem(String, RootDiagnostic)
	ImplicitProblem(String, ImplicitDiagnostic)
	SyntaxProblem(ModuleId, SyntaxDiagnosticAt)
	ImportProblem(ModuleId, Span, ImportFailure)
```

### 4.3 Tables in the output, and only these

| Table | Key | Authoritative or derived |
| --- | --- | --- |
| `modules` | `ModuleId` (position) | Authoritative: each module's source, origin, reach, text, line starts and syntax |
| `ModuleSyntax.items` | position | Authoritative: the tree |
| `ModuleSyntax.definitions`, `imports` | local id | Derived from the tree, built by `IdMint` as the parser builds the tree, read-only |
| `import_targets` | `ImportId` (local index) | Authoritative: the module graph |
| `name_ids` | `SpellingId` (local index) | Authoritative: the link step's interning |
| `names` | `NameId` | Authoritative: each name's text; its slot index is derived and read-only |
| `packages` | `PackageId` | Authoritative |
| `roots`, `implicit` | position | Authoritative |
| `DiscoveredModule.bases` | per module | Derived at link from the counts of the modules before it, read-only |

### 4.4 Program-wide indexes

A program-wide id is the module's base plus the local index. A later stage
keeps a fact per id in a column sized by the program's count of that family,
and reaches it in one of two ways:

```blorp
pure func expression_count(program: DiscoveredProgram) -> Int


---
The program-wide index of an expression of a module's own tree: the module's
base plus the id's local index. Total: no list is read. For walkers, which
hold the module whose tree they walk (`module.bases.expression_index(id)`).
---
pure func expression_index(bases: SyntaxBases, id: ExpressionId) -> Int


---
The program-wide index of an expression of any module, for an id that crossed
modules (one a referent or another stage's table handed over). It reads the
id's module first, so it returns `Option` (section 4.5).
---
pure func program_expression_index(program: DiscoveredProgram, id: ExpressionId) -> Option[Int]

-- ... and the same three for definitions, imports, statements, blocks,
-- patterns, written types, dimensions, name uses, binders and type binders.
```

The module-level form is for ids read from that module's own tree, which is
how a walker meets nearly every id. A walker that holds an id from another
module (the `DefinitionId` of a referent, say) uses the program-level form.

### 4.5 Reading by id, and what a miss is

With trees, a reader holds the node it is working on, so by-id reads are few:

```blorp
pure func module(program: DiscoveredProgram, id: ModuleId) -> Option[DiscoveredModule]
pure func definition(program: DiscoveredProgram, id: DefinitionId) -> Option[Definition]
pure func import_target(program: DiscoveredProgram, id: ImportId) -> Option[ImportTarget]
pure func name_id(program: DiscoveredProgram, spelling: SpellingId) -> Option[NameId]
pure func name_text(program: DiscoveredProgram, name: NameId) -> Option[String]
pure func find_name(program: DiscoveredProgram, text: String) -> Option[NameId]
```

Five of these six read a list at an index the program issued, as do the
eleven `program_*_index` functions. `find_name` is a search that may miss.

**There is no silent fallback in any build.** Blorp's `List.get` returns
`Option`, and the language has no abort for a defect. So:

- the sixteen issued-index reads return `Option`;
- a reader turns `None` for an issued id into an `InternalCompilerError`
  value with `?=`, naming the id family and the local index;
- the stage's outcome carries that error to the driver;
- the driver prints `internal compiler error: ...` and exits nonzero, in
  debug and release builds alike.

`Option[Int]` is unboxed (Appendix B), so the indexes cost a branch, not an
allocation. The `UNREACHABLE_*` constants and every fallback row are gone.
L1 in section 7 is the language work that would make these reads total.

### 4.6 What freeze checks: nothing

The link step cannot fail, and there is no freeze. Every invariant of today's
`invariants/` is either a property of the types or a property of how
`IdMint` mints and builds:

| Today's violation kind | Why it cannot happen |
| --- | --- |
| `DanglingReference`, `RangeOutOfBounds` | No stored row index. Ids come only from `IdMint`. A child is a field. |
| `NodeChildNotBeforeParent`, `UnreferencedNode`, `NodeReferencedTwice`, `SubtreeNotContiguous` | Trees: a node is a value held by exactly one parent. Post-order minting gives contiguous subtree ranges within each family. |
| `NodeArityMismatch`, `PayloadOutOfRange`, `NameSpanOnWrongNodeKind`, `NodeNameSpanMissing`, `ElseKeywordMismatch`, `LocalFunctionNodeMismatch` | Typed forms with typed fields, and the bounded shapes of section 3.1 |
| `BodyRootOutsideModule`, `ModuleRangesOverlap` | A module's syntax is its own value |
| `DuplicateSideRow`, `SignatureCountMismatch`, `SideTableUnsorted` | `Option` and required fields in the owning record |
| `SpanOutsideSources`, `SpanPastSourceEnd` | Spans are made by the lexer from positions in the text and joined by `span_covering`. Admission checks that the text fits a span. |
| `NameSpanOutsideItsSpan` | The name is a token inside the node's token range |
| `SeededNameMoved`, `InternIndexMismatch`, `ParallelTableMismatch`, `SigilSpellingMismatch`, `DimensionSigilNameMissing` | No seeded names, no parallel tables, no sigil names in the stage. Each interning table is opaque, with one mutator. |
| `RecoveryDiagnosticOutsideModule` | No recovery nodes |

Two properties rest on the parser's discipline rather than on types:

1. **Every id a module issued is held exactly once in its tree**, at the
   field section 3.3 names for it. The mint makes "an id without a node"
   impossible. Two things it cannot rule out (section 3.15): a node dropped
   after it was built (the no-discard rule), and a duplicate id from a stale
   or second mint, since Blorp has no linear types. The id census finds both,
   a gap or a duplicate:
   - as a corpus test in the `compiler-new` gate, over every accepted module;
   - at link in debug builds, inside a `debug:` block, so any debug compile
     catches a parser change that breaks it.

   It walks the tree, collects each family's ids, and requires exactly
   `0 ..< count`.
2. **Spans lie within their source.** `pack_span` keeps a debug assertion,
   and the census checks every span against its text.

Bounds the parser enforces without a shape (the 64-field variant limit) are
pinned by fixtures and not claimed by the types.

### 4.7 Effects on resolution

These are the changes to what resolution reads, for the resolution design
(the resolution stage design, `b54cc4dbc`). What typecheck and Core lowering read is specified when those
stages are designed (section 1, non-goals).

**Input**

- **E1.** The input is `DiscoveredProgram`, not `FrontendTables`. Resolution
  never sees a module with a syntax error, a rejected root, a missing
  implicit module or an import whose source could not be used: discovery
  produced a failure report instead of a program. Its plan to resolve
  "anyway" after discovery diagnostics does not arise. `ImportUnresolved` is
  the only failed import target it sees, so
  `UnresolvedCause.ReportedAtImport` remains, for names reached through such
  an import.

**Walking bodies**

- **E2.** Bodies are walked by exhaustive `match` over typed forms. The
  following go: `NodeKind`, `node_row`, `child_at(row, n)` with its
  totality argument from `NodeArityMismatch`, `name_role` per `NodeKind`,
  and the rule that derives a name's role from its parent. A name's
  role is its type:
  - every `NameUse` gets exactly one outcome, including "decided by type"
    for members and record fields;
  - every `Binder` and `TypeBinder` declares;
  - a `WrittenName` is never resolution's.

  The `NameRole` enum and the freeze checks `NameOutcomeMissing` and
  `NameOutcomeDuplicated` reduce to "the walk visits each `NameUse` field
  once". A column sized by `name_use_count` holds the outcomes.
- **E3.** The walk can be recursive, with left spines walked by loops
  (section 3.14). The explicit `WalkStep` stack is optional. Scopes are
  structural: a `Block`'s `leading` statements then `last`; a `ForStatement`
  visits `iterable`, then declares `binder`, then walks `body`.
- **E4.** `NodeRange` visibility and `LocalBindingRow.visible` are not needed
  for the walk. If a check of "every local is in scope" is still wanted,
  name-use and binder ids are in source order within a module.

**Names and binders**

- **E5.** Binder identity:
  - **Always-binding sites** carry a `BinderId`: `var`, typed and `?=`
    bindings, parameters (each name of a tuple parameter), lambda
    parameters, loop variables, `with`, `select`, `on` and spread binders,
    destructured names.
  - **Declared type parameters** carry a `TypeBinderId`.
  - **The two sites that declare or refer** are `NameUse`s: an assignment
    target `x = v`, and a name pattern.

  A resolution `LocalBindingId` can be replaced by a union of binding sites
  (below). Either way, `NodeBinderRow`, `ParameterBinderRow` and the
  `DeclaredTypeParameterId` that R0 asked discovery for go.

  **Resolution stores each binding's form and mutability itself**, in a table keyed by binding, when it decides the binding. Discovery's
  syntax says only where a name is written. Whether `x = v` declared an
  immutable binding or assigned a mutable one is resolution's decision.
  Every later reader (the capture rules, typecheck, the ownership analysis)
  takes it from resolution, never by re-deriving it from the statement form.

```blorp
union LocalBinding:
	DeclaredBy(BinderId)
	DeclaredByAssignment(NameUseId)
	DeclaredByPattern(NameUseId)
```

- **E6.** No `ParameterId`. A parameter's names are `Binder`s, and its
  ordinal is its position in `Signature.parameters`.
- **E7.** Bounds, supertraits, the trait of `implements`, import items and
  constructor lists in imports are `NameUse`s. `BoundTraitRow`,
  `SupertraitTargetRow`, `ImplementedTraitRow`, `ImportItemBindingRow` and
  `ImportVariantBindingRow` become outcomes of those uses, or rows keyed by
  `NameUseId`. A pure/impure pair for an import item needs an outcome form
  for "these definitions". R0's `ImportItemVariantId` is moot.
- **E8.** A member after a dot (`x.f`, `m.f`, the method of `x.f(...)`) is a
  `NameUse`. A qualified read, a method's candidate set, or "decided by type"
  is the outcome of the member's `NameUseId`, not of the field-access node.
- **E9.** Names in the tree are `SpellingId`s. `program.name_id(spelling)`
  gives the `NameId` that namespace columns are indexed by: one read per
  use. The seeded vocabulary is gone from discovery, so resolution's
  catalogs find a well-known name once with `find_name("Int")`.
- **E10.** `#N` is `NamedDimension(NameUse)` with spelling `N`. There is no
  sigil spelling. `Self` and `void` as types are `NamedType` uses; `()` is
  `VoidType`.

**Definitions, modules and imports**

- **E11.** A definition's kind is its `Definition` variant. There is no
  `DefinitionKind` and no `IMPL_NAME`: an implementation has no name and
  declares none. Owners are structural. Enum cases are `EnumCase`, distinct
  from union variants.
- **E12.** `DefinitionId` and every node id are packed (module, local) and
  minted in completion order (members before owners). Code that assumed
  pre-order or "sorted by owner" must not. The trees make sorted side tables
  unnecessary. Columns use `program.definition_index(id)`.
- **E13.** `ModuleMemberIndex` is built from each module's `items`, the
  top-level declarations.
- **E14.** Local functions are `LocalFunctionStatement(LocalFunction)` inline
  in the block, with their `DefinitionId`. There is no payload indirection.
- **E15.** An import's target is `program.import_target(import.id)`. The
  default alias of an import is its path's last part. R0's rename of
  `resolution_diagnostics` to `module_graph_diagnostics` is moot: there is
  no such table.
- **E16.** Qualified forms state their qualifier as a `NameUse`:
  `QualifiedType`, `QualifiedConstructorPattern`, `TraitReference.qualifier`.
  R0's `PatternQualifierNode` comment correction is moot.

**Other forms**

- **E17.** An interpolation hole has its own `ExpressionId` (`Hole.id`). A
  hole's value is resolved in the enclosing scope.
- **E18.** Blocks are not expressions, and statements are their own records
  with `StatementId`. `Body`, `CaseBody`, `ElseBody` and the block-typed
  fields say where a block can stand. A concurrent task is a statement, and a
  `for ... concurrently` body is a block: `CaptureRow.closure` is a
  `StatementId`, a `BlockId` or (for a lambda or `detach`) an
  `ExpressionId`.
- **E19.** Literals carry checked values. Spans pack the `ModuleId` as their
  source.
- **E20.** R0 shrinks to nothing: every discovery addition it asked for is
  either here by construction or no longer needed.
- **E21. Spans by id.** A fact or problem that outlives the walk
  carries the `NameUse` (which has its span) or a `Span`, never an id alone.
  An id is identity; a span is where to point. A reader that will report must
  keep the span, because no table maps an id back to a node. If a later
  reader ever needs that mapping, it is one derived column per family, built
  by `IdMint` as it mints; it is not built now.

## 5. Interning and literal values

### 5.1 Names

| Text | Where it is interned | Why |
| --- | --- | --- |
| Names (identifiers, keywords read as names, dimension names) | Per module, by the lexer (and by the parser for hole tokens and keyword names), in the module's `Spellings`; merged once by `link` into the program's `NameTable` | The parse stays a pure function of one module. The merge costs one insert per distinct spelling per module. The program-wide `NameId`s come out in today's order. |
| Paths (module paths, root requests) | Not interned; a `String` in the one record that owns it | Each path has one owner, and the by-path index is walk state, not output |

```blorp
---
One module's spellings, interned as the lexer meets them. `intern_slice` is
the only mutator; a slice that is already present allocates nothing. The slot
index (open addressing over FNV-style hashes, as `tables/intern_index.brp`
does today) is private and cannot disagree with the texts.
---
opaque type Spellings = InternedSpellings

private record InternedSpellings {
	module: ModuleId,
	texts: List[String],
	slots: List[Int]
}


pure func intern_slice(spellings: Spellings, source: String, start: Int, end: Int) -> (Spellings, SpellingId)
pure func spelling_text(spellings: Spellings, spelling: SpellingId) -> Option[String]


---
The program's names: each distinct spelling once, at its `NameId`.
`link` builds it; it is read-only afterwards.
---
opaque type NameTable = InternedNames

private record InternedNames {
	texts: List[String],
	slots: List[Int]
}
```

Link moves each new spelling's `String` into the `NameTable` without copying
it: the same string object, retained. A module's `Spellings` is dropped after
link. Its texts now live in `names` and its mapping in `name_ids`, so a
name's text lives in exactly one table.

### 5.2 Literal values

**Discovery does not intern literal texts.** The backend's static string pool
deduplicates string constants by content when it emits C. Interning them in
discovery as well would be a second deduplication that no reader uses: no
later stage compares literals by identity.

**The tree stores each literal in checked form**, so no later stage re-parses
or re-validates digits:

| Literal | Stored as | Checked by |
| --- | --- | --- |
| Integer | `Int128`: the magnitude (a leading `-` is a `Unary` or a pattern's `Sign`) | The lexer, against `Int128`'s maximum: the same cap as today's lexer (`INT128_MAX_DECIMAL`, `IntegerLiteralOverflow`), so the accepted range is unchanged. Typecheck then checks that the value fits the type it gives the literal (rule A). |
| Float | `DecimalFloat` (below) | The lexer: the digits are well formed and the value is finite as a `Float` |
| String | `String`: the decoded text (escapes applied; joined lines for a pipe string) | The lexer's escape checks |
| Character | `Char` | The lexer |
| Dimension literal | `Int128` | The lexer, as an integer |
| Concurrency count | `PositiveCount` | The parser (`positive_count`) |

```blorp
---
A float literal: its decimal digits as written, made only by the lexer after
checking that they are well formed and finite. A later stage converts it once
to the width typecheck chose, each conversion rounding directly from the
decimal.
---
opaque type DecimalFloat = String

pure func to_float(value: DecimalFloat) -> Float
pure func to_float32(value: DecimalFloat) -> Float32
pure func written_digits(value: DecimalFloat) -> String
```

**Floats keep their digits: a deliberate departure from storing a checked
`Float`** (section 9, D1). A stored 64-bit `Float` would make a `Float32`
literal round twice, decimal to 64-bit and then 64-bit to 32-bit, which can
differ from rounding the decimal once, as the C compiler does today with
`1.5f`. The opaque `DecimalFloat` is checked like a value and converts once,
from the decimal, to the width typecheck picks.

Integers are exact in `Int128`, so they need no such care. The adapter
rebuilds the old AST's digit strings from the source text under each
literal's span, so written digits such as a leading zero are kept exactly,
and no digit string is stored in the stage for the old compiler's sake.

## 6. The legacy adapter and the parity gates

### 6.1 Where it lives: `blorp/src/compiler/`

Two modules in `blorp/src/compiler/` connect the stage to the existing
compiler, and they are the only compiler modules that import `compiler_new`
(`temporary_cross_owner_imports` in `blorp/source_ownership.json`):

```
blorp/src/compiler/
  discovery_front_end.brp   composes discovery's inputs (provider, lookup roots,
                            implicit modules), renders what the stage rejected,
                            and hands the program to the adapter
  discovery_adapter.brp     the stage's output -> FrontendCompilationGraph: modules,
                            names, roots, edges and validation; declarations,
                            bodies, types and patterns to the old AST; the legacy
                            name table
```

`blorp/src/lib/source_graph.brp` always takes the current discovery stage and
legacy adapter path. The old `BLORP_FRONT_END` switch and its
`ExistingDiscovery` arm have already been removed. M5's comparison is an
internal test-only choice between the stage's table and tree paths; it must
not restore a public front-end switch. The adapter may later split into a
folder if it grows past one readable module. After the tree rewrite its
expected size is 1,500 to 2,000 lines.

**Layout rules**, enforced by `scripts/check-blorp-layout` and
`blorp/source_ownership.json`:

- `compiler_new/` imports nothing from `compiler/`.
- `compiler/` imports `compiler_new/` only through the two modules above, and
  only while the adapter exists. They are rewritten in place over the trees
  (M3 to M6) and deleted when typecheck reads the trees directly.
- `lib/` does not import `compiler_new/`; the commands reach the stage through
  `lib/source_graph.brp`.

### 6.2 How it changes

Today the adapter is 4,019 lines. Most of it does three things:

- builds a `DeclarationReader` of 25 derived owner indexes, to find each
  declaration's members, bounds, payloads and bodies again;
- walks a module's post-order node block by position, keeping each node's
  rebuilt value in a slot, with `NotYetBuilt` and `MalformedNode` for
  children of the wrong kind or count;
- propagates a `Result` through every row read: 139 sites of
  `MissingTableRow`, `MalformedNode`, `NotYetBuilt` or `Result[`.

Over trees it is a structural map. Each typed form has one target form, and
the old AST is close in shape (`ParsedExpr`, `ParsedPattern`,
`ParsedTypeExpr`, `ParsedDecl`):

```blorp
private pure func legacy_expression(context: LegacyContext, expression: Expression) -> ParsedExpr:
	location: SourceLocation = context.location(expression.span)

	match expression.kind:
		NameReference(use):
			ParsedNameExpr(context.identifier(use.name))
		Call(callee, arguments):
			ParsedCallExpr(
				context.legacy_expression(callee),
				arguments.map(pure func(argument): context.legacy_expression(argument)),
				location,
			)
		IntegerLiteral(_):
			ParsedIntLiteralExpr(context.written_text(expression.span), location)
		-- ... one arm per form, no catch-all. `Binary` chains are folded from a
		-- loop over the left spine (section 3.14), not by recursion on `left`.
```

The adapter's tree-shape errors all go, because a tree cannot lack a row,
have a child of the wrong kind, or be a body root that is not an expression:
`MissingTableRow`, `NotAWrittenType`, `MalformedNode`,
`BodyRootNotAnExpression` and `ModuleWithoutRequest`. Two errors remain:

- `GraphRejected`, the old graph validation refusing the modules, which is
  the program's error;
- the internal-error value of section 4.5, for a by-id read that misses.

Legacy-only facts move into the adapter:

- **Seeded vocabulary.** The 236 names at pinned ids that match the old
  compiler's `NAME_ID_*` constants.
- **Sigil spellings.** `#N` beside `N`, as the old compiler's identifier for
  a dimension name.
- **Module names.** The old front end's module names (`LegacyModuleNaming`),
  unchanged.
- **Old encodings.** Literal digit strings from the source text, `()` as
  `ParsedNamedType(Void)`, `_: T` parameters as name binders, enum cases as
  payload-free variants, and interpolated strings in the form
  `finalize_interpolation_program` leaves.

**The C output and the `#N` order.** The adapter's legacy name
table is:

1. the seeded block;
2. the program's names in `NameId` order;
3. the `#N` spellings, in the order of their plain names.

Today the lexer interleaves each `#N` right after its first dimension use, so
every name interned after the first sigil spelling has a different legacy
`NameId` here.

The C changes only if a later pass orders or spells something by `NameId`.
The flip found the self-compile C byte-identical between two front ends that
already number names differently past the seeds, so no change is expected.
M5 checks it.

If the C does change, it changes only in id-derived names. Acceptance
criterion 2 already compares those after normalizing. Reproducing today's
interleaving exactly would need the stage to remember where each spelling's
first sigil use fell, which is legacy knowledge in the stage. This design
does not take that.

### 6.3 Parity during the transition

The stage is the only compilation front end now, so every increment must keep
it passing every default and premerge gate. M3 to M5 compare the table and
tree paths inside that stage; the old parser remains an independent parity
oracle while its other users still need it. The proofs:

- **The full-AST differential**
  (`blorp/test/compiler/tools/discovery_adapter_differential.brp`, run by
  `scripts/compiler-new-parity`).
  - It compares the old parser's parsed program with the stage's adapted
    program for every corpus module and the root runs, through
    `parsed_ast_json.brp`.
  - From M3 it gains a third side: the tree path (new parse, new adapter).
    Both stage paths must equal the old parser's AST, and therefore each
    other, on every module.
  - This is the main correctness proof. It covers every field the old AST
    holds, spans included.
- **The syntax dump differential.** The old AST has no ids, so it cannot
  catch a wrong id or a dropped node.
  - A canonical text form of each tree (`syntax/dump.brp`) and a dumper of
    today's tables into the same form are compared over the corpus while
    both paths exist.
  - Spellings are printed as text, so the two name numberings need not
    agree.
  - Ids are printed as module-local indexes and must be equal for the
    families both sides have.
  - Together with the id census, this proves the ids.
- **Diagnostics.**
  - The parity gate's first-diagnostic comparison against the old compiler
    holds unchanged.
  - A per-module comparison of every rendered diagnostic, old stage path
    against tree path, covers fixtures and corpus, so the second and later
    diagnostics are pinned too. The one deliberate difference is listed:
    the broken import item of section 3.17.
- **Module order.** `discovery_module_order_dump.brp` runs on the tree path
  against `legacy_module_order_dump.brp`, unchanged.
- **The self-compile.** C is byte-identical, or identical after normalizing
  id-derived names, from `bin/blorp` and a stage-2 `-O2` compiler.

## 7. Measured cost and open budget

The 2026-10-01 baselines used the table stage on the self-compile input
(`blorp/src/main.brp`, 449 modules), at `-O2`. They are historical controls,
not a matched baseline for a candidate built from this revision.

| Boundary | Allocations | Instructions | Peak RSS |
| --- | ---: | ---: | ---: |
| Stage, cost tool `tables` | 0.578 M | 4.20 G | 131.5 MB |
| Stage plus adapter, `graph` | 7.65 M | 9.17 G | 324.6 MB |
| Whole self-compile, stage-2 `-O2` | 211.4 M | 405.3 G | 2.15 GB |

The original shape probes and node census are in
[`discovery_redesign_probes_2026-10-01.md`](../benchmarks/results/discovery_redesign_probes_2026-10-01.md)
and Appendices A and B. M0 then built a throwaway parser for all 13,105
function bodies in that input. Its measured source, coverage, counters and
limitations are in
[`discovery_redesign_m0_2026-10-02.md`](../benchmarks/results/discovery_redesign_m0_2026-10-02.md).
That prototype used `struct` for `WrittenName`, `NameUse`, `Binder` and other
small values. It did not build the declaration parser, link step or tree
adapter, and it used a different compiler baseline. It is evidence about
cost mechanisms, not a performance prediction for the record-based design
in section 3 or for today's compiler.

### 7.1 What M0 measured

| Same-body boundary | Allocations | Retired instructions |
| --- | ---: | ---: |
| Existing table parser | 6,623 | 0.939 G |
| M0 tree parser | 11,383,762 | 6.801 G |

M0 found 2.32 M retained tree objects (131.8 MB) and about 9.1 M transient
state and tuple allocations. The tree stage's own peak was estimated at
about 207 MB against 122.7 MB for the then-current table parser, an 84 MB
increase. The 5.9 G instruction difference for body parsing alone was
+1.45% of that revision's 405.3 G whole self-compile, before any adapter
saving. M0 did not measure a completed tree front end or a whole-compiler
candidate against the flip ceiling.

The old section 7 estimates that priced an allocation at 60 to 80
instructions and predicted a 4.6 to 5.6 G tree stage were disproved.
M0 observed roughly 510 instructions for one retained variant box's
lifecycle and 600 per allocation over the body parse. Its exact retained
census included 0.46 M boxes for the proposed name and binder values when
they were `struct` payloads. Ordinary `record` values change that shape,
so no allocation or instruction total for the section 3 design is claimed
from M0's totals.

### 7.2 Costs to measure as the design lands

| Boundary | Evidence and required next measurement |
| --- | --- |
| Syntax values | M1's proposed `record` names, binders, counts, annotations and forms need representative construction and return probes. Keep the role and id contract; measure its cost rather than reverting to `struct` to match M0. |
| Tokens | M2 compares the provisional scalar `fixed record Token` with an ordinary `record` on the same token corpus, including retained bytes and instructions. Keep an inline token only while it is an explicit, measured storage exception under the record simplification plan. |
| Parser hand-off | M0 attributed about 9.1 M allocations to transient state, tuples and other parse work. Its experimental tuple hand-off compiler reduced the body parse by 1.50 M allocations and 0.80 G instructions, but was not the current incremental implementation. Re-measure after the actual tuple increments. |
| Link and removed tables | Deleting freeze, openings, side tables, sigil interning and owner searches may save work; M0 did not measure these deletions or the new link. Measure the complete stage at M5. |
| Tree adapter | M0 did not build it. Measure the structural adapter at M5 instead of carrying forward the old 6.5 M allocation or 3.0 to 3.7 G instruction estimates. |
| Whole compiler | M5 and M6 use matched stage-2 `-O2` compilers on identical frozen inputs, with output identity and phase-local counters. Earlier stage-only or cross-compiler figures are not acceptance evidence. |

The tree program should be released after the adapter builds the old AST.
M0's stage-local RSS increase does not establish the whole-compiler peak;
M5 measures the lifetime and peak directly. Value unions in record fields,
record placement and arena allocation are possible later compiler work,
not prerequisites silently assumed in the estimates here. The
[record simplification roadmap](FIXED_LAYOUT_ROADMAP.md) owns product
representation choices; the
[tuple hand-off plan](VALUE_TUPLES_AND_STATE_HANDOFF.md) owns its
increments.

### 7.3 The M6 ceiling

The tree path becomes the stage's default at M6 only if all three hold on
the self-compile, with a stage-2 `-O2` compiler against a matched main
baseline:

- **Retired instructions:** at most +1.0%, median of 3 back to back.
- **Peak RSS:** at most +5%, median of 3.
- **Wall time:** at most +1.0%, on the median of at least 5 interleaved
  runs of each side.

These ceilings are unchanged and are not loosened for an unrelated compiler
change. M0 showed that its historical body parser alone exceeded the
instruction ceiling on its compiler. M1 to M5 can proceed; M6 waits on
increments 1 to 4 of
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md)
and increment 5 if the re-measured M0 after 4 still needs it. The
[record simplification roadmap](FIXED_LAYOUT_ROADMAP.md) also changes
representation and cost: rerun the record-shaped parser and whole
stage against the then-current compiler before applying the ceiling.
If it is missed, reduce measured parser or adapter work without weakening
the output contract.

A separate language improvement, L1, could make issued-index reads total.
Today `List.get` returns `Option`, so a by-id miss becomes an internal
error (section 4.5). A branded index handed out at append would remove
that error path, but is not required for M1 to M6.

Parallel parsing (section 2.6) targets wall time, not instructions. It
still needs the measured task-fiber overhead and concurrent provider reads
addressed first.

## 8. Migration plan

The stage stays the only compilation front end throughout. Each increment is
one change and lands with its proof. Old code is deleted in the increment
that makes it unreachable, not later. M6 switches the stage's internal
default from tables to trees; it does not switch between two compiler front
ends. The old parser still serves `compile --ast`, test discovery, the LSP
and parity checks, as [`DISCOVERY_ACCEPTANCE_ROADMAP.md`](DISCOVERY_ACCEPTANCE_ROADMAP.md)
records.

**Completed prerequisites:** `=` in expression positions is a parse error
in both parsers (`d460bac5f`). M-1's remaining syntax restrictions and
teaching messages landed in `020b95d90`. M0's throwaway parser and cost
report are retained in
[`discovery_redesign_m0_2026-10-02.md`](../benchmarks/results/discovery_redesign_m0_2026-10-02.md);
the prototype is not the M1 implementation.

| # | Change | Proof | Deleted |
| --- | --- | --- | --- |
| **M1** | Retain and rerun the opaque-type import-cycle repro (section 3.15), fixing the compiler if it still fails. Then `syntax/`: every type of section 3, using ordinary `record` for the proposed name and syntax values; `syntax/ids.brp` with `IdMint`; the layout rule that confines `IdMint` to `parse/` and tests; `syntax/dump.brp`; and unit tests that build each form through the mint and dump it. Nothing calls it yet. | Tests; `compiler-new` gate; the layout check rejects an import of `IdMint` from outside `parse/`; record-shape construction and return costs recorded (section 7.2) | none |
| **M2** | The lexer becomes `lex_module(module, text) -> LexedModule`, with per-module `Spellings`, checked `LiteralValue`s and `InterpolationScan`. The existing builder path consumes `LexedModule` through a bridge that interns spellings into the builder and rewrites token payloads. Decide the provisional `fixed record Token` from a same-corpus record/layout probe. | Token parity test unchanged; `tables` dump identical; token storage and bridge costs recorded | the lexer's builder appenders; transient interpolation tables |
| **M3** | `parse/` over trees, declaration level: module items, imports, foreign blocks, signatures, type parameters, bounds, written types, dimensions, patterns. Bodies are skipped by layout. The temporary `ValueRecordSpelling` preserves today's `struct` and `fixed record` syntax for the adapter until record semantics converge. Then the tree adapter's declaration half, behind a test-only entry. | The differential's declaration-level comparison, tree path against the old parser including both value-record spellings; per-module declaration diagnostics equal to today's stage | none |
| **M4** | The body parser over trees (statements, blocks, expressions), and the tree adapter's body half. | Full-AST differential: the tree path equals the old parser on every corpus module and root run; every rendered diagnostic per module equals today's stage, except the listed broken-import case; the syntax dump differential matches; the id census passes; the deep-chain tests of section 3.14 pass through parse, dump, adapter and the old typecheck | none |
| **M5** | `sources/module_walk.brp`, `link/`, `DiscoveryOutcome`, and `discovery_front_end.brp` on the tree path, behind an internal test-only selection, with `compiler-new`, `cli` and `package` gates exercised on both stage paths. | Module-order parity; self-compile C identical (or normalized); cost measured with the cost tool's `tables` and `graph` modes and the self-compile against matched main | none |
| **M6** | Make the tree path the stage's default, within the ceiling of section 7.3, and delete the table path in the same change. | Every default and premerge gate on the new default; self-compile C identical; the ceiling's measurement record | `tables/` (builder, node builder, rows, row kinds' node part, node kind classes, `frontend_tables`, `discovery_tables`, `invariants/`, `intern_index` moved, `name_vocabulary` moved to the adapter): about 11,600 lines; the table-reading bodies of `compiler/discovery_adapter.brp` and `compiler/discovery_front_end.brp` (the files stay, now reading trees); `builder_rule_probe`, `builder_append_probe`, `test_invariants`, `test_allocation_budget` (replaced by a syntax allocation test pinning allocations per construct, so a compiler improvement shows as a decrease and a regression fails) |
| **M7** | Documentation: `DISCOVERY_TABLES_DESIGN.md` is replaced by this document's settled form; `ARCHITECTURE.md`, `DISCOVERY_ACCEPTANCE_ROADMAP.md` and `docs/README.md` are updated; the resolution design takes section 4.7. | `git diff --check`; link check | the superseded design text |

Ordering and parallelism:

- The `=` and M-1 language prerequisites have landed.
- M1 begins by verifying the opaque-type import-cycle repro on its own base.
- M1 and M2 are independent of each other.
- M3 needs M1 and M2, M4 needs M3, and M5 needs M4.
- G2 (tuple hand-off, `VALUE_TUPLES_AND_STATE_HANDOFF.md`) proceeds in parallel. M1 to M5 do not wait on it; M6 does (its increments 1 to 4, and 5 if the re-measured M0 still needs it).

Syntax stays frozen from M1 through M4, so the differential compares against
a fixed target.

## 9. Remaining disagreements

**D1. Floats keep their decimal digits (section 5.2).** The alternative is a
`Float` that has passed the overflow check. This design stores an opaque
`DecimalFloat` that only the lexer makes, after the same check, because a
stored 64-bit `Float` would round a `Float32` literal twice. The lexer checks
finiteness as a 64-bit `Float`; a literal that is finite there but overflows
`Float32` is still rejected by typecheck, which knows the width.
*Recommendation:* accept `DecimalFloat`. Its opaque type gives the "checked,
not re-validated" guarantee, without double rounding.

**D2. The flip ceiling** is decided (sections 7.3 and 10): +1.0% instructions, +5%
peak RSS, and +1.0% wall time on the median of at least 5 interleaved runs,
which keeps the measurement outside the about 0.8% pairing noise of a median
of 3 back to back.

**D3. Names decided by type are `NameUse`s.** Record
field names and the member after a dot get a `NameUseId`, and resolution
records "decided by type" for them. The alternative was a separate
member-name family that resolution never sees. *Recommendation:* one
family, because a dotted member is sometimes resolution's (`m.f`) and
sometimes typecheck's (`x.f`), and one id per written name keeps "one outcome
per use" uniform.

**D4. The `#N` order in the legacy name table** may change id-derived names
in the generated C (section 6.2). *Recommendation:* accept a normalized C
comparison if it does, rather than carrying legacy order in the stage.

## 10. Decisions taken

| Topic | Decision | Applied in |
| --- | --- | --- |
| Recovery | A module with a syntax error has no tree; discovery reports its diagnostics. The simplest output: a program, or a failure report. Not designed around today's LSP. | 2.3, 2.4, 3.17, 4.2, E1 |
| Ids | Packed (module, local) ids; a program-wide id is the module's base plus the local id. Ids are managed exclusively behind the opaque boundary. | 3.3, 3.15, 3.16, 4.4 |
| Names | Interned per module | 3.2, 5.1 |
| Declare-or-refer names | `x = v` and name patterns stay `NameUse`s that resolution decides; resolution stores binding form and mutability itself | 3.12, E5 |
| Forms only typecheck rejected | Both parsers reject them; assignment-as-statement landed in `d460bac5f`, and M-1 landed in `020b95d90`. | 3.9, 3.11, 3.12, 3.19, 8 |
| Product spelling | Ordinary `record` is the syntax-value target. `struct` and `fixed record` are temporary source forms represented by `ValueRecordSpelling` until the record simplification sequence removes their separate semantics. A scalar token may temporarily use `fixed record` only with a measured storage reason. | 2.3, 3.4, 3.7, 7.2, M2, M3 |
| Flip timing | The stage switches from tables to trees only within +1% retired instructions, +5% peak RSS and +1% wall time. M6 waits on tuple increments 1 to 4, and increment 5 if re-measured M0 still needs it; record-shaped costs are measured again. M1 to M5 do not wait. | 0, 7.3, 8 |
| Glue location | `compiler/discovery_front_end.brp` and `compiler/discovery_adapter.brp`, the only compiler modules importing `compiler_new`; rewritten in place over trees, deleted when typecheck reads trees directly | 6.1, M6 |
| Literals | Discovery does not intern literal texts (the backend pools strings); the tree stores checked values | 5.2 |
| Downstream reads | Typecheck and Core lowering reads come later; E1 to E21 cover resolution | 1, 4.7 |

## Appendix A. Node census

Taken at `519e7311c` with the census tool in the probes record over
`discover(blorp/src/main.brp)` with the compiler's implicit modules:

- 449 modules; 32,098 definitions; 35,443 parameters; 902 type parameters
- 954,978 nodes; 874,344 child edges; 162,465 name-span rows

Nodes by kind, largest first:

| Kind | Count | Kind | Count | Kind | Count |
| --- | ---: | --- | ---: | --- | ---: |
| `IdentifierNode` | 282,208 | `NamedTypeNode` | 104,774 | `CallNode` | 97,175 |
| `BlockNode` | 77,521 | `FieldAccessNode` | 59,010 | `NamePatternNode` | 53,435 |
| `MatchCaseNode` | 40,127 | `ConstructorPatternNode` | 26,608 | `StringLiteralNode` | 24,638 |
| `RecordFieldNode` | 19,685 | `WildcardPatternNode` | 17,713 | `AssignmentNode` | 13,983 |
| `MatchNode` | 11,210 | `IfNode` | 10,821 | `IntegerLiteralNode` | 10,306 |
| `AddNode` | 9,308 | `TypedBindingNode` | 9,287 | `ListLiteralNode` | 6,699 |
| `FalseLiteralNode` | 6,527 | `VarDeclarationNode` | 6,506 | `EqualNode` | 5,889 |
| `RecordLiteralNode` | 5,575 | `QuestionBindNode` | 4,766 | `AndNode` | 3,781 |
| `TrueLiteralNode` | 3,267 | `TupleNode` | 3,216 | `LoopBinderNode` | 3,070 |
| `ForNode` | 3,032 | `OrNode` | 2,403 | `InterpolationTextNode` | 2,181 |
| `LambdaParameterNode` | 1,986 | `RecordUpdateNode` | 1,939 | `NotNode` | 1,850 |
| `AddAssignNode` | 1,731 | `InterpolationHoleNode` | 1,705 | `VoidNode` | 1,677 |
| `LambdaNode` | 1,622 | `StringPatternNode` | 1,491 | `TuplePatternNode` | 965 |

Every other kind has fewer than 1,000 nodes. The select, concurrency and
dictionary forms are rare or absent on this input; the corpus run of the
differential covers them.

## Appendix B. Allocation probes

Run with `bin/blorp run --release --no-format --memory-stats` at
`519e7311c`, 10,000 values each, kept in a list. The programs and the census
tool are in
[`benchmarks/results/discovery_redesign_probes_2026-10-01.md`](../benchmarks/results/discovery_redesign_probes_2026-10-01.md);
they are not committed as tests, because no gate would run them.

| Probe | Allocations per value |
| --- | ---: |
| payload-free variant | 0.0013 (list growth only) |
| variant `Name(Int, Int, Int)` | 1 |
| variant `Spotted(Spot, Int)`, `Spot` a struct | 2 |
| variant `Call(CallParts)`, a record with an empty list and a 1-allocation child | 3 |
| variant `Call(CallParts)` with a two-element list of payload-free leaves | 3 |
| variant `Pair(Node, Node, Int, Int)` of payload-free leaves | 1 |
| record holding `Some(Int)` / `None` | 1 / 1 (the record only) |
| variant `WithOptional(Some(existing node), Int)` / `None` | 1 / 1 |
| variant with `Some(new record)` | 2 |
| `(state, leaf)` returned and destructured, leaf a 2-field record | 4 (leaf 1, overhead 3) |
| the same, two nested calls, one leaf kept | 9 |
| `(state, value)` where `state` holds a growing `List[Int]` | 3 per call, linear (no copy of the list per call: 200,000 calls finish without quadratic time) |
