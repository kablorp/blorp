# Discovery Redesign: Per-Module Parses into Typed Syntax Trees

This is the design and migration record for the typed-tree path. The syntax
prerequisite M-1 has landed, M0 measured a throwaway body-parser prototype,
and M1 and M2 are implemented and validated. M3 remains open on rejected
module diagnostic parity; bounded M4 global expression slices are implemented,
and M5 to M7 remain open. It replaces the data model of
[`DISCOVERY_TABLES_DESIGN.md`](DISCOVERY_TABLES_DESIGN.md) (one builder threaded
through every module, a flat node table and about 50 side tables) with:

The default front end still uses the normalized tables.

The future schema below is specified in full; function bodies appear where
their shape matters. Ordinary `record` is the syntax-value target under the
[record simplification roadmap](FIXED_LAYOUT_ROADMAP.md). The historical
[M0 prototype](../benchmarks/results/discovery_redesign_m0_2026-10-02.md)
used several `struct` values and does not price this exact design.
[Census and initial probes](../benchmarks/results/discovery_redesign_probes_2026-10-01.md)
are historical evidence, not a current candidate baseline.

Syntax prerequisites are already current language rules: assignment is a
statement, calls have no named arguments, and type parameters are explicit
except those introduced by an `implements` receiver. The parser rejects
syntactically forbidden forms before typecheck. The retained M0 report is
a throwaway cost experiment, not M1 implementation. M1 retained and passed
the opaque-import-cycle check (3.15); M6 depends on tuple increments (7.3).
Implementation and tests win if later work diverges, and this plan must be
updated in the same change.

## 1. Goals, principles, non-goals, and what the redesign replaces

The proposal makes discovery's output directly readable by later stages:
typed trees retain structure, while each later stage keeps its own facts in
columns keyed by parser-issued identity. There is no flatten step. Syntax
categories have distinct record/union forms, optional parts use `Option`,
and bounded sequences encode the grammar's arity. Exhaustive readers need
no kind-dependent payload decoding or child-position checks.

The parser alone constructs syntax. Its opaque `IdMint` builds each node
with its ID in one step; it never predicts an ID. Each name's role is explicit:
`WrittenName` for names nobody resolves, `Binder`/`TypeBinder` for
introductions, and `NameUse` for scope- or type-decided uses. Sections 3.2,
3.3 and 3.15 specify that boundary. Resolution determines whether assignment
targets/name patterns declare or refer, and stores binding form/mutability.

Each pure per-module parse owns temporary state and returns a complete tree
or diagnostics. Paths, origin and package belong to the module walk; import
targets belong to its outcomes. Per-module names are merged once at link.
The definitions/import indexes share the records in the tree and stay
read-only. Missing issued IDs are internal errors in every build (4.5);
no placeholder or fallback row reaches a later stage.

This replaces the current global builder, opening/closing protocols,
post-order node/edge tables, sorted optional side tables and final invariant
walk with per-module state and structurally complete values. Required parts
become fields; optional parts become `Option`; owner relationships become
containment. `SourceId` merges with `ModuleId`; paths/literals become values.
Legacy seed/sigil spellings move to the adapter. Sections 3.19 and 4.6 map the
current forms/invariants to the proposed replacement.

Code shape and correctness come first. Today's compiler costs are measured
rather than encoded as parser calling conventions. The hard M6 ceiling
still applies; sections 7 and 8 own its budget and tuple prerequisites.

### Non-goals

- Comments/layout trivia and an error-tolerant editing tree. The formatter
  keeps its parser until a separate lossless-tree or trivia design replaces
  it. Today's LSP integration neither requires nor constrains this proposal.
- Incremental rediscovery and parallel execution. Per-module isolation
  enables later work; section 2.6 gives parallelism's extra prerequisites.
- Name resolution and type inference. Section 4.7 specifies resolution's
  changed input; typecheck and Core reads are specified when those stages
  are designed.

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
accepted `ModuleSyntax`; its definitions index still owns partial syntax.

`diagnostics` is every diagnostic the module's lexing and parsing reported,
in the order reported today: the lexer's, then the parser's, with an
interpolation hole's lexer diagnostics where the parser reaches the hole.

`kept_imports` is each `Import` (one module path with its alias and selected
items) during whose parse no diagnostic was reported: the diagnostics count
was the same after its last token as before its first. An import that
reported anything is dropped whole, items included. The walk resolves the kept
imports and loads their modules, so those modules' own problems are reported
in the same run, as they are today. Rejection keeps the authoritative
`definitions` index minted during parsing: a diagnostic such as
`DuplicateField(DefinitionId)` still refers to an earlier field even when its
containing declaration has no accepted tree. Final parser spellings and source
positions survive with this index until the last reader finishes.
---
record RejectedSyntax {
	diagnostics: AtLeastOne[SyntaxDiagnosticAt],
	kept_imports: List[Import],
	definitions: List[Definition]
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

It is a hot, scalar-payload transient value in token lists, not part of the tree
or the public product model. Both `record` and `fixed record` now have managed
semantics; the spelling does not promise inline placement or zero allocation.
M2 measures the actual token representation against token parity and cost
gates. It is private to `lex/` and the parser's cursor module, and is read only
through accessors that check the kind:

```blorp
pure func token_spelling(token: Token) -> Option[SpellingId]
pure func token_literal(token: Token) -> Option[LiteralIndex]
pure func token_codepoint(token: Token) -> Option[Char]
pure func token_interpolation(token: Token) -> Option[InterpolationIndex]
```

Token storage is an internal optimization boundary. Remeasure after compiler
record-placement changes, and choose a stage-local representation only with
matched cost and parity evidence.

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
| `foreign_blocks.brp` | `ForeignBlock`, `ForeignArgument`, `ForeignFunction`, `ForeignCName` (section 3.6) |
| `declarations.brp` | Every declaration record, `Function`, `Signature`, `Annotation`, and the parameter, type-parameter, trait-reference and constraint records (sections 3.7, 3.8) |
| `definitions.brp` | `Definition`, the definitions index's union (section 3.18) |
| `types.brp` | `WrittenType`, `TypeArgument`, `BoundedTypeArgument` (grouped single or argument receiver bounds), `Dimension` and their kinds (section 3.9) |
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
  at the node around it. Today that needs `NodeNameSpanRow`; here it is a field.
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
with different parts get separate records: a resource type has a cleanup
builtin and a builtin type does not; an `enum`
case has no payload and a `union` variant may. Otherwise one record would
have to allow a combination the grammar forbids. All source record forms
accept type parameters and already have ordinary managed record semantics.
`RecordDeclarationForm` retains ordinary `record` or `fixed record` source
spelling for formatting and parsed-AST adaptation, not for a distinct layout
or ownership policy. `struct` is an ordinary identifier.

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
	form: RecordDeclarationForm,
	name: WrittenName,
	type_parameters: List[TypeParameter],
	fields: List[FieldDeclaration],
	span: Span
}


enum RecordDeclarationForm:
	OrdinaryRecord
	FixedRecord


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

The current M1 implementation temporarily imports `FunctionAnnotation` from
`tables/row_kinds.brp`, so the table path and tree records share one identical
enum while both exist. M6 moves or deletes that table ownership with the table
path. This is a transitional ownership exception, not a second syntax shape.

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
	BoundedType(BoundedTypeArgument)                        -- `(T: Eq)` in receiver context, including a receiver function result


---
One argument in brackets or parentheses: a type, a dimension, or, in an
`implements` receiver only, a bounded type parameter.
---
union TypeArgument:
	TypeArgumentType(WrittenType)
	DimensionArgument(Dimension)
	BoundedArgument(BoundedTypeArgument)


---
`T: Eq + Hash` in an `implements` receiver, either as a grouped single form
or inside its arguments (`implements Show for Box[T: Eq]`): the type parameter
that impl introduces, with its bounds. `BoundedType` owns a `WrittenTypeId`
for the grouped single form; `BoundedArgument` has no enclosing type ID. Both share
this payload. A bound written in any other type is a parse error.
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
only inside a receiver. `BoundedType` represents a grouped single bound,
including a receiver function result (`implements Show for (T: Eq)`).
Bare root `T: Eq` leaves the colon to the implementation owner. Typecheck
resolves the receiver's bare and bounded
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
split above follows that. Assignment is a statement only. The parser rejects
`for` where a value is required (`x = for ...`), and a one-element tuple
`(x,)`; both were accepted before and neither has a syntax type here (decided
2026-10-05).

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

M4's gate adds deep-chain tests, through parse, dump, ID census and the
adapter's legacy projection:

- a 5,000-term `+`;
- a 2,000-call method chain;
- a 2,000-deep `else if` chain (an `else if` nests in the else branch);
- a 1,000-deep nested list literal (right-nesting, bounded by brackets).

The current adapter's 6,000-operand chain test is kept.

The old typecheck is outside this proof (owner decision, 2026-10-05). Its
recursive walks overflow on these chains, and it is to be replaced whole
rather than made iterative, so the gate does not require deep chains to
typecheck through it.

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

**The opaque-cycle prerequisite is fixed and retained.** At M0, a compiler bug blocked
this layout: `syntax/ids.brp` imports the node types it builds (from
`expressions.brp`, `declarations.brp` and the others), and those modules
import the id types from `ids.brp`. An opaque type inside an import cycle is
rejected by that compiler: a record field of the opaque type failed with `Record field
'id': expected d.DId, got DId`. The probe pairs `d.brp`/`e.brp` and `m3.brp`
failed; the same shapes without the cycle (`f.brp`, `g.brp`, `m4.brp`)
passed. Commit `9172b35e0` fixed the identity mismatch. The retained regression
is [`opaque_type_import_cycle.brp`](../blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/opaque_type_import_cycle.brp),
with its `opaque_cycle_ids` and `opaque_cycle_syntax` helpers; it covers records,
unions, aliases, globals and implementations across the cycle. It passed
`bin/blorp check --no-format` on the M1 integration base `684f5e5`.
M1 also compiles its real mint/node import cycles through the syntax tests.
The design keeps the mint
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

Information may be discarded only after no surviving tree, diagnostic, fact,
or identifier needs it. This applies to rejected parses as well as accepted
ones. A recovery placeholder may be dropped only when no surviving value
refers to it; rejection alone does not establish that condition. The mint's
exact definitions index therefore survives a rejected declaration while any
diagnostic can refer to its definitions (section 3.17).

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

The current node-kind families in `tables/row_kinds.brp` map as follows.
This is the migration mapping; the historical frequency census belongs to
the [probe report](../benchmarks/results/discovery_redesign_probes_2026-10-01.md).
Forbidden forms are rejected by the current assignment-statement and explicit
parameter rules, not represented as accepted tree forms.

| Today's node kind(s) | New home |
| --- | --- |
| `IdentifierNode` | `NameReference(NameUse)` |
| `IntegerLiteralNode`, `FloatLiteralNode` | `IntegerLiteral(Int128)`, `FloatLiteral(DecimalFloat)` |
| `StringLiteralNode`, `RawStringLiteralNode`, `PipeStringLiteralNode`, `RawPipeStringLiteralNode` | `StringLiteral(StringForm, String)` |
| `InterpolatedStringNode`, `InterpolatedPipeStringNode` | `InterpolatedString(InterpolationForm, List[InterpolationPiece])` |
| `InterpolationTextNode` | `InterpolationText(String)` |
| `InterpolationHoleNode` | `InterpolationHole(Hole)` |
| `TrueLiteralNode`, `FalseLiteralNode` | `BooleanLiteral(Bool)` |
| `CharLiteralNode` | `CharacterLiteral(Char)` |
| `NegateNode`, `NotNode` | `Unary(UnaryOperator, Expression)` |
| `DetachNode` | `Detach(Expression)` |
| `AddNode` ... `GreaterEqualNode` (11 kinds) | `Binary(BinaryOperator, ...)` |
| `AndNode`, `OrNode` | `ShortCircuit(LogicalOperator, ...)` |
| `RangeNode` | `RangeExpression(Expression, Expression)` |
| `CallNode` | `Call(Expression, List[Expression])` |
| `FieldAccessNode` | `FieldAccess(Expression, NameUse)` |
| `SubscriptNode` | `Subscript(Expression, AtLeastOne[Expression])` |
| `ListLiteralNode`, `TupleNode`, `VectorLiteralNode` | `ListLiteral`, `TupleLiteral(SmallTuple[...])`, `VectorLiteral` |
| `RecordLiteralNode`, `RecordUpdateNode` | `RecordLiteral(List[NamedValue])`, `RecordUpdate(Expression, List[NamedValue])` |
| `RecordFieldNode` | `NamedValue` |
| `DictLiteralNode`, `DictEntryNode` | `DictLiteral(List[DictEntry])`, `DictEntry` |
| `IntoOpaqueNode`, `FromOpaqueNode` | `OpaqueConversion(OpaqueDirection, WrittenType, Expression)` |
| `BlockNode` | `Block` (in `Body`, `CaseBody`, `ElseBody` and the block fields); never an expression |
| `IfNode` | `If(IfExpression)`; an `else if` is `ElseIf(ElseIfExpression)` |
| `MatchNode`, `MatchCaseNode` | `Match(Expression, List[MatchCase])`, `MatchCase` |
| `SelectNode`, `SelectReceiveArmNode`, `SelectSealedArmNode`, `SelectAfterArmNode` | `Select(List[SelectArm])`, `SelectArmKind` |
| `WithNode`, `WithBindingNode`, `WithTryBindingNode`, `WithErrorMapNode` | `With(WithExpression)`, `WithBinding`, `WithTryBinding`, `ErrorMap` |
| `DebugBlockNode` | `DebugBlock(Block)` |
| `LambdaNode`, `PureLambdaNode`, `LambdaParameterNode` | `Lambda(LambdaExpression)` with `purity`; `LambdaParameter` |
| `LocalFunctionNode` | `LocalFunctionStatement(LocalFunction)`, inline, with its `DefinitionId` |
| `WhileNode` | `WhileLoop(WhileStatement)` |
| `ForNode`, `LoopBinderNode`, `TupleLoopBinderNode` | `ForLoop(ForStatement)`, `LoopBinder` |
| `ConcurrentForNode`, `ConcurrentBlockNode`, `ConcurrentParameterNode` | `ConcurrentForLoop`, `ConcurrentBlock`, `CountParameter` / `TimeoutParameter` |
| `BreakNode`, `ContinueNode` | `Break`, `Continue` |
| `VoidNode` | `VoidValue` |
| `BuiltinNode`, `NamedBuiltinNode` | `CompilerBuiltin(Option[String])` |
| `MissingExpressionNode`, `MissingPatternNode`, `MissingTypeNode` | none: a module with a syntax error has no tree (3.17) |
| `VarDeclarationNode` | `VariableDeclaration(VariableStatement)` |
| `TypedBindingNode` | `TypedBinding(TypedBindingStatement)` |
| `AssignmentNode` as a statement | `Assignment(AssignmentStatement)` |
| `AssignmentNode` anywhere else (a list element, a call argument such as `print(ys[0] = 3)`, a condition) | rejected: assignment is a statement only |
| `QuestionBindNode` | `QuestionBinding(QuestionBindingStatement)` |
| `AddAssignNode` ... `DivideAssignNode` | `CompoundAssignment(...)`; `_ += v` rejected by M-1 |
| `SubscriptAssignmentNode` | `SubscriptAssignment(SubscriptAssignmentStatement)` |
| `TupleDestructureNode`, `DestructureBinderNode` | `TupleDestructure(...)`, `BindingTarget` |
| `WildcardPatternNode` | `WildcardPattern` |
| `NamePatternNode` | `NamePattern(NameUse)` |
| `IntegerPatternNode`, `NegativeIntegerPatternNode`, `FloatPatternNode`, `NegativeFloatPatternNode` | `IntegerPattern(Sign, Int128)`, `FloatPattern(Sign, DecimalFloat)` |
| `StringPatternNode`, `RawStringPatternNode`, `PipeStringPatternNode`, `RawPipeStringPatternNode` | `StringPattern(StringForm, String)` |
| `CharPatternNode`, `TruePatternNode`, `FalsePatternNode` | `CharacterPattern(Char)`, `BooleanPattern(Bool)` |
| `ConstructorPatternNode` | `ConstructorPattern(NameUse, List[Pattern])` |
| `QualifiedConstructorPatternNode`, `PatternQualifierNode` | `QualifiedConstructorPattern(NameUse, NameUse, List[Pattern])` |
| `TuplePatternNode`, `ListPatternNode` | `TuplePattern(SmallTuple[...])`, `ListPattern` |
| `ListSpreadNameNode`, `ListSpreadWildcardNode` | `ListSpread` with `BindingTarget` |
| `OrPatternNode` | `AlternativePatterns(AtLeastTwo[Pattern])` |
| `NamedTypeNode` | `NamedType(NameUse, List[TypeArgument])`; `()` is `VoidType` |
| `QualifiedTypeNode`, `TypeQualifierNode` | `QualifiedType(NameUse, NameUse, List[TypeArgument])` |
| `BoundedTypeNode` | `BoundedType(BoundedTypeArgument)` for a grouped single bound in receiver context, or `BoundedArgument(BoundedTypeArgument)` inside receiver arguments; rejected by M-1 in every other type |
| `TypeBoundNode`, `QualifiedTypeBoundNode` | `TraitReference` |
| `DimensionNameTypeNode`, `VariadicDimensionNameTypeNode` | `NamedDimension(NameUse)`, `VariadicNamedDimension(NameUse)` |
| `DimensionWildcardTypeNode`, `VariadicDimensionWildcardTypeNode` | `WildcardDimension`, `VariadicWildcardDimension` |
| `DimensionLiteralTypeNode` | `LiteralDimension(Int128)` |
| `DimensionAddTypeNode` ... `DimensionDivideTypeNode` | `DimensionArithmetic(DimensionOperator, ...)` |
| A dimension in a type position (`rows: #N`, `-> #M`, `x: #3`) | `DimensionType(Dimension)` |
| `RangeTypeNode` | `RangeType(Dimension)` |
| `TupleTypeNode` | `TupleType(SmallTuple[TypeArgument])` |
| `FunctionTypeNode`, `PureFunctionTypeNode` | `FunctionType(Purity, List[TypeArgument], WrittenType)` |
| `ArrayTypeNode` | `ArrayType(WrittenType, AtLeastOne[Dimension])` |

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

The module records hold typed trees; link does not flatten them. Resolution
walks scope order, typecheck evaluation order and Core lowering the same
structure again. A node table would make all these readers decode structure,
as the current adapter does. Facts remain separate columns keyed by identity,
so immutable syntax can be shared across phases rather than copied.
If a measured whole-program scan later benefits from flat rows, derive them
in one walk; there is no current consumer requiring that representation.

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
	spellings: Spellings,
	definitions: List[Definition]
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

The historical [allocation probes](../benchmarks/results/discovery_redesign_probes_2026-10-01.md)
found `Option[Int]` unboxed, so the indexes cost a branch, not an
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
- **E21. Information lifetime.** An id is identity; its exact lookup must
  survive as long as a reader needs information behind that identity.
  `IdMint` already builds the authoritative `DefinitionId -> Definition`
  index, and accepted and rejected syntax retain it. In particular,
  `DuplicateField(first)` resolves the earlier field's exact spelling and
  span through that index. Rendering rejects missing entries, cross-module
  ids, wrong definition kinds and forward references; it never guesses a
  name or position. A fact can instead carry its `NameUse` or `Span` when
  that contains all information its readers need. Derived indexes for other
  id families are built only when a reader needs them, and no referenced
  information is discarded before its last reader finishes.

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
pure func written_digits(value: DecimalFloat) -> String
```

A direct `DecimalFloat` to `Float32` reader requires a decimal-to-Float32
primitive: the current `String.parse_float` returns a 64-bit `Float`, so
converting that result to `Float32` would round twice. This reader remains a
consumer prerequisite before any later stage needs a numeric `Float32`
value. M1 and M2 retain the original digits, and the legacy adapter passes
them to the existing backend, which already emits literals at their chosen
width. They do not materialize an intermediate `Float32` value.

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
folder if needed for readable ownership boundaries.

**Layout rules**, enforced by `scripts/check-blorp-layout` and
`blorp/source_ownership.json`:

- `compiler_new/` imports nothing from `compiler/`.
- `compiler/` imports `compiler_new/` only through the two modules above, and
  only while the adapter exists. They are rewritten in place over the trees
  (M3 to M6) and deleted when typecheck reads the trees directly.
- `lib/` does not import `compiler_new/`; the commands reach the stage through
  `lib/source_graph.brp`.

### 6.2 How it changes

The current adapter's table reconstruction does three things:

- builds a `DeclarationReader` of 25 derived owner indexes, to find each
  declaration's members, bounds, payloads and bodies again;
- walks a module's post-order node block by position, keeping each node's
  rebuilt value in a slot, with `NotYetBuilt` and `MalformedNode` for
  children of the wrong kind or count;
- propagates checked row/shape failures through `Result`.

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

Use the [Worker Checklist](WORKER_CHECKLIST.md) and
[measurement protocol](../benchmarks/README.md#self-compile-measurement-protocol).
The workload is the reachable self-compile graph from `blorp/src/main.brp`,
including implicit modules. Compare stage-only, stage plus adapter/graph and
whole-compiler boundaries separately, with matching source/binary provenance.
Historical reports are not matched controls for today's compiler.

### 7.1 What M0 established

The [initial census/probes](../benchmarks/results/discovery_redesign_probes_2026-10-01.md)
and [M0 report](../benchmarks/results/discovery_redesign_m0_2026-10-02.md)
retain exact sources, counters, commands, coverage and limitations.
M0 built a throwaway body parser, without declaration parsing, link or tree
adapter. It disproved the original cheap-allocation estimates: retained
variant lifecycles and transient state/tuple handoffs dominated cost, and
body parsing alone exceeded the instruction ceiling on its historical
compiler. It also increased stage-local memory.

M0's `struct` name/binder payloads differ from the ordinary-record schema
here. Its totals are mechanism evidence, not a prediction of the completed
design or a whole-compiler candidate. Record-shaped construction, actual
tuple increments, complete link/adapter savings and whole-compiler lifetimes
must be measured before M6.

### 7.2 Costs to measure as the design lands

| Boundary | Evidence and required next measurement |
| --- | --- |
| Syntax values | M1 construction and return probes are retained in [`discovery_redesign_record_shapes_2026-10-03.md`](../benchmarks/results/discovery_redesign_record_shapes_2026-10-03.md). Their compiler and record layout predate managed record unification; remeasure on the current bootstrap and tuple increments while retaining the role and identity contract. |
| Tokens | M2 measures the provisional `Token` on the same token corpus, including retained bytes and instructions. `fixed record` versus `record` does not itself select inline storage: both are managed. Any future inline placement requires a separate, measured record optimization. |
| Pure lexer and temporary bridge | The pre-unification matched stage measurement is retained in [`discovery_redesign_m2_current_2026-10-03.md`](../benchmarks/results/discovery_redesign_m2_current_2026-10-03.md). Its historical tables identity and cost ledger do not establish post-unification costs; remeasure with current managed records and bootstrap. |
| Parser hand-off | M0 attributed substantial cost to transient state/tuple work. Its experimental tuple compiler was not the incremental implementation. Re-measure after the actual tuple increments; the report retains the historical comparison. |
| Link and removed tables | Deleting freeze, openings, side tables, sigil interning and owner searches may save work; M0 did not measure these deletions or the new link. Measure the complete stage at M5. |
| Tree adapter | M0 did not build it. Measure the structural adapter at M5; do not carry forward the disproved estimates. |
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

The schema assumes the current syntax rules described above. No prerequisite
language migration remains in this plan; the import-cycle check is still
required at M1. The M0 prototype is evidence only.

**Current milestone status:** M1 and M2 are complete. M1's pre-unification ordinary-record
construction costs and token comparison are in
[`discovery_redesign_record_shapes_2026-10-03.md`](../benchmarks/results/discovery_redesign_record_shapes_2026-10-03.md).
M2's pre-unification stage cost and byte-identical tables dump are in
[`discovery_redesign_m2_current_2026-10-03.md`](../benchmarks/results/discovery_redesign_m2_current_2026-10-03.md).
M3 has the parse state, token cursor, imports, written types, dimensions,
patterns and the shared field, type-parameter, signature and constraint
grammar. Direct declaration leaves now cover ordinary and fixed records through
one generic-capable `RecordDeclaration`, aliases, builtin and resource types, unions, enums and
top-level function headers. Complete foreign blocks cover their attributes,
bodyless function signatures and optional C names. Trait previews cover type
parameters, supertraits and method headers. Their method previews distinguish
abstract methods from authored deferred default bodies and reject a promised
body that is missing. They mint no declaration definitions: M4 replays each
completed method in source order and mints the containing trait last, preserving
child ID order when deferred bodies become syntax trees. Declaration-prefix
scanning preserves documentation, annotations, visibility and purity and composes
those prefixes with the function header parser.
Implementation-method previews reuse that signature grammar and require authored
deferred bodies, leaving abstract and forward method states unrepresentable.
Receiver-specific type parsing preserves bounded arguments and the grouped bounded
type forms that can occur at a receiver root or function result. Implementation
previews cover the single trait target, receiver and method headers without minting
declaration definitions. M4 replays from the authoritative pre-declaration state,
completes methods in source order and mints the containing implementation last.
Global-header previews preserve their metadata, names and written types while
stopping at an explicit initializer entry; M4 owns initializer expressions and
completes the global declaration. A function header records `ForwardDeclaration`
or `SkippedBody(DeferredBody)` explicitly, preserving forward declarations as
authored syntax while M4 owns body trees.
Import blocks now own their layout and repeated child imports. A test-only
single-declaration dispatcher routes every completed leaf and declaration preview,
and stops explicitly at global initializer or rejected-declaration boundaries.
Both record spellings use the same type-parameter and field grammar and have
managed semantics. The explicit `RecordDeclarationForm` preserves authored
spelling for diagnostics and legacy projection. `struct` is an ordinary
identifier; the retired declaration spelling is rejected by the current
parser grammar.
The module preamble recognizes a leading module docstring only when its next
non-newline token is `import`; other docstrings remain declaration prefixes.
A bounded test-only module scan retains those previews in source order and stops
at global initializers or the first rejected declaration. It
does not claim an accepted `ModuleSyntax`, final ID census or forward pairing.
The test-only legacy declaration projection now maps the completed non-body
prefix through one shared legacy name table. It covers both record spellings, aliases, builtin and resource types, unions, enums, import blocks
and foreign blocks, including module and declaration documentation, visibility,
annotations and normalized import paths. At a function, trait, implementation
or global initializer it now projects the body-independent header structurally;
it still stops at that deferred owner and at rejected or non-progressing scan
boundaries, and never constructs a `ParsedProgram`. Unit
differentials compare every projected declaration with the old parser and pin
name-id continuity across declarations and projections. The additive
declaration-prefix corpus differential now runs this projection from each exact
accepted old-parser source and program, threads one shared synthesized name table,
and fails closed on projection errors, rejected or non-progressing accepted
boundaries, malformed protocol output and any unlisted field difference. Its
first full corpus run compared 3,307 accepted modules and 4,403 completed
declarations with zero tree-prefix differences or errors. Distinct per-module
coverage included all completed forms: 2,095 import blocks, 69 foreign blocks,
447 ordinary records, 118 `struct` declarations, 10 `fixed record` declarations,
168 aliases, 29 builtin types, 10 resource types, 309 unions and 127 enums.
The deferred function stop now projects a body-free legacy header and compares
its name, keyword, type parameters and bounds, parameters and types, result,
dimension constraints, purity, annotations and documentation through the shared
AST JSON encoding. The same corpus run validated 2,683 function-header stops
with no structural or boundary difference while leaving bodies unconstructed.
It also validated all 452 global-initializer stops by comparing the global name,
optional written type, constant or mutable form, documentation, visibility and
exact assignment and initializer-entry boundary. The selected global header
advances the shared name table, while its initializer and any later declaration
cannot contribute names. A later 3,404-file parity run, whose 3,307 accepted
modules entered declaration-prefix comparison, compared 60 trait headers and
57 implementation headers, including every ordered method header,
abstract/default or required-body presence and per-method boundary. Names from
deferred method bodies and later declarations remain outside the projected name
table. Module assembly, rejected-module tree diagnostic parity, the remaining
global initializer expression families, trait and implementation bodies and
completed owners, and forward pairing remain open.
The standalone alias, builtin-type, enum, ordinary-record, union and
fixed-record rejection previews now own a shared opaque `RejectedPreview`:
source, line starts, final parser spellings, all issued definitions and ordered
diagnostics. Its constructor rejects an empty diagnostic list. `new_parse_state`
validates that line starts exactly match the source in one scan without building
a second list; malformed lexical inputs fail before layout or rendering. The bounded
`render_rejected_duplicate_field` seam resolves the surviving `DefinitionId`
against that immutable index and shares wording with the table renderer.
Focused regressions cover both record spellings, a nonzero earlier field id, and invalid missing, cross-module,
wrong-kind and forward references. This closes the preview lifetime blocker;
full rejected-module assembly and diagnostic parity remain open.

The syntax diagnostic payload audit found one definition identity
(`DuplicateField`) and spelling identities in `ReservedKeywordAsName`,
`UnknownAnnotation`, `ConcurrentDuplicateParameter`,
`ConcurrentUnknownParameter` and `ConcurrentForUnknownParameter`. The shared
rejection owner keeps both lookup
families. Other syntax payloads carry direct values or spans and retain their
source with the same owner.

The first bounded M4 slice completes a global only when its initializer is one
same-line ordinary name, checked decimal integer literal or checked float
literal and its following token proves an EOF or newline boundary rather than
a leading-dot continuation. It checks the whole supported shape before minting
anything. A name mints its `NameUse`, `Expression`, and global definition in
that order; a numeric literal mints only its `Expression` and global definition.
The tree keeps the checked integer magnitude or decimal float while the legacy
projection recovers the exact authored digits, so `007` and `007.500` remain
unchanged. Every unsupported expression returns the exact
authoritative initializer state. The existing M3 scan remains the default; an
explicit test-only scan opts into atomic completion. Its legacy projection
compares the full `ParsedVarDecl`, including the initializer and complete span,
while threading the shared name table through repeated spellings and later
modules. After a fresh rebuild, the 3,404-file parity gate passed with zero
mismatched files. Its declaration-prefix run compared 3,308 accepted modules
and 4,862 completed declarations, then stopped at 2,782 functions, 60 traits,
59 implementations, 339 unsupported global initializers and 68 ends of source,
with no rejected or non-progressing accepted boundary. This proves only the
three atomic initializer forms: general expressions, complete bodies, module
assembly, final ID census and the rest of M4 remain open.


A bounded diagnostic gate now renders every `SyntaxDiagnostic` variant
from the retained rejection owner. Spelling payloads resolve through its final
spelling table; `DuplicateField` resolves through its exact definitions index.
The tree and table renderers share context-free wording helpers. A separate
whole-source rejected-declaration scan continues leaf recovery to EOF and
compares every ordered diagnostic, including help, byte spans and tab-aware
locations, against the table renderer. Raw legacy differences are always
reported, and counted as baseline differences only after exact tree/table
equality, preserving the stage's existing help and wording changes. It explicitly
defers functions, traits, implementations and globals before their omitted
bodies or initializers can affect diagnostics. Those deferred counts remain
outside this proof; full rejected-module parity remains open.

A second bounded M4 expression increment recognizes same-line names, checked numeric
literals, booleans, void, grouping, unary operators and the shared binary
operator table, including logical and range expressions. It first builds an
ID-free recipe and validates the complete boundary. Only then does it mint
syntax identities in source order. Unsupported postfix, aggregate, control
flow and multiline shapes restore the exact entry state. An explicit prefix
scan opts into this expression grammar; production discovery remains unchanged.
The legacy projection walks expression continuations iteratively, preserving
source-order names and spans. Grouped integer literals recover digits from
an exact balanced token shape, with a projection error when provenance is
missing. This increment does not complete function bodies, blocks, module
assembly, forward pairing or the full M4 deep-chain gate.

Another bounded M4 increment extends that same-line grammar with positional
calls, member access and nonempty subscripts. Calls may have no arguments;
calls and subscripts accept trailing commas. Recognition keeps ID-free recipes
until the complete initializer boundary is accepted. Minting walks receiver
and callee spines iteratively, then issues member names and argument/index
expressions in written order. The legacy projection uses continuations for
those same spines and keeps raw call, field and subscript syntax; later phases
decide what the calls and accesses mean.

Supported postfix rejection covers missing closing delimiters at EOF, empty
subscripts and missing member names. Comma-first arguments, mismatched closing
delimiters after a parsed item, aggregate operands and multiline tails remain
explicitly unsupported and restore the exact entry state. This remains a test-only
expression completion seam; statements, bodies and complete module assembly
are still open.

The next bounded M4 expression slice is same-line list literals, using the
existing `ListLiteral` variant. It must retain child-first source-order IDs,
exact literal token provenance, closing-bracket diagnostics and unsupported
input rollback. Its depth evidence includes the 1,000-nested-list case through
parse, dump, ID census and legacy projection. Tuples, braced aggregates,
strings and control expressions follow in separate slices; the complete M4
gate still requires bodies.

Argument nesting is the one recursion in the postfix grammar. It follows
brackets the source itself nests, as the frozen parser does, and a test parses
1,000 nested calls `f(f(...))`.

The postfix slice was validated on a fresh build that includes main
`ff4da4b31`. Focused checks passed 152/152 and declaration-scan checks 14/14,
all with zero leaked objects under `--leak-check`. The broad gates passed
`compiler-new` 837/837 and `compiler-new-parity` 3,548/3,548, with zero
mismatched files under the gate's existing normalization; `compiler-blorp`
passed 6,594/6,594 at main `dde591ecd`. Depth checks cover a 2,000-call chain
through parsing, dumping and ID census, and 5,000 mixed field/call/subscript
steps through legacy projection. The expression opt-in prefix compared 5,200
completed declarations in 3,398 legacy-accepted corpus modules. It stopped at
2,891 functions, 61 traits, 61 implementations, 310 unsupported globals and
75 ends of source, with zero rejected or non-progress stops.
`scripts/compiler-new-parity` (also run by `scripts/test compiler-new-parity`)
prints these counts on its "tree prefix agrees with the existing parser for
every corpus file as a root" line. These are prefix comparisons, not complete
body or module parity.

Validation before the main reconciliation, at `a5ae15eab`:

The combined fresh-build focused run passed 121/121 tests, including a
5,000-term binary chain through parsing and legacy projection. The separate
rejection differential read 3,500 source files, skipped 3,320 accepted by the
legacy parser, and compared all 35 ordered diagnostics in 27 complete rejected
leaf modules with zero tree/table differences or errors. It reported 31 raw
legacy baseline differences and explicitly deferred 122 function owners,
4 traits, 1 implementation and 26 global initializers. Deferred owners are not
rejected-module parity evidence. Logs are retained at
`/tmp/blorp-discovery-expression-final` for this local run.
The broader fresh-build gates also passed: `compiler-new` 805/805,
`compiler-blorp` 6,460/6,460 and `compiler-new-parity` 3,508/3,508. The
expression opt-in corpus prefix compared 5,028 completed declarations and
stopped at 2,845 functions, 60 traits, 59 implementations, 326 unsupported
global initializers and 68 ends of source, with zero rejected or non-progress
stops. These counts establish the bounded expression seam, not complete body
or module parity. Independent code review approved the change with no
remaining findings.

The main reconciliation uses the managed-record bootstrap `dev-d44472d3a5d0`.
Both record spellings share one generic-capable declaration type, and `struct`
remains an ordinary identifier. The current lexer, bridge, parser and full-load
allocation contracts are measured separately in
[`discovery_merge_allocations_2026-10-04.md`](../benchmarks/results/discovery_merge_allocations_2026-10-04.md);
historical inline-record counts are not current cost evidence. Rejected type
parameters stop the tree record parser before its field grammar. If recovery
then reaches an identifier that may start a global, the rejection scan reports
that deferred owner and excludes the source from complete diagnostic parity.

The reconciled fresh-build checks passed 147/147 focused discovery tests,
6/6 ownership regressions with zero reported leaks, and `compiler-new`
825/825. The rejected corpus read 3,519 modules, skipped 3,342 accepted by the
legacy parser, and compared 35 diagnostics in 27 complete rejected leaf modules:
zero strict tree/table differences or errors, with 31 separately reported legacy
baseline differences. It deferred 119 function owners, 4 traits, 1 implementation
and 26 globals; those 150 owners remain outside the proof. Logs are in
`/tmp/blorp-merge-publish-tests/`.

| # | Change | Proof | Deleted |
| --- | --- | --- | --- |
| **M1** | Retain and rerun the opaque-type import-cycle repro (section 3.15), fixing the compiler if it still fails. Then `syntax/`: every type of section 3, using ordinary `record` for the proposed name and syntax values; `syntax/ids.brp` with `IdMint`; the layout rule that confines `IdMint` to `parse/` and tests; `syntax/dump.brp`; and unit tests that build each form through the mint and dump it. Nothing calls it yet. | Tests; `compiler-new` gate; the layout check rejects an import of `IdMint` from outside `parse/`; record-shape construction and return costs recorded (section 7.2) | none |
| **M2** | The lexer becomes `lex_module(module, text) -> LexedModule`, with per-module `Spellings`, checked `LiteralValue`s and `InterpolationScan`. The existing builder path consumes `LexedModule` through a bridge that interns spellings into the builder and rewrites token payloads. Measure the provisional managed `Token` on the same corpus; any future inline placement is a separate record optimization, not a source-spelling choice. | Token parity test unchanged; `tables` dump identical; token storage and bridge costs recorded | the lexer's builder appenders; transient interpolation tables |
| **M3** | `parse/` over trees, declaration level: module items, imports, foreign blocks, signatures, type parameters, bounds, written types, dimensions, patterns. Bodies are skipped by layout. One `RecordDeclaration` retains `RecordDeclarationForm(OrdinaryRecord, FixedRecord)` for source spelling and parsed-AST adaptation; both forms have managed record semantics. Then the tree adapter's declaration half, behind a test-only entry. | The differential's declaration-level comparison, tree path against the old parser including both record spellings and ordinary `struct` identifiers; per-module declaration diagnostics equal to today's stage | none |
| **M4** | The body parser over trees (statements, blocks, expressions), and the tree adapter's body half. | Full-AST differential: the tree path equals the old parser on every corpus module and root run; every rendered diagnostic per module equals today's stage, except the listed broken-import case; the syntax dump differential matches; the id census passes; the deep-chain tests of section 3.14 pass through parse, dump, ID census and adapter (the old typecheck is excluded, section 3.14) | none |
| **M5** | `sources/module_walk.brp`, `link/`, `DiscoveryOutcome`, and `discovery_front_end.brp` on the tree path, behind an internal test-only selection, with `compiler-new`, `cli` and `package` gates exercised on both stage paths. | Module-order parity; self-compile C identical (or normalized); cost measured with the cost tool's `tables` and `graph` modes and the self-compile against matched main | none |
| **M6** | Make the tree path the stage's default, within the ceiling of section 7.3, and delete the table path in the same change. | Every default and premerge gate on the new default; self-compile C identical; the ceiling's measurement record | `tables/` (builder, node builder, rows, row kinds' node part, node kind classes, `frontend_tables`, `discovery_tables`, `invariants/`, `intern_index` moved, `name_vocabulary` moved to the adapter): about 11,600 lines; the table-reading bodies of `compiler/discovery_adapter.brp` and `compiler/discovery_front_end.brp` (the files stay, now reading trees); `builder_rule_probe`, `builder_append_probe`, `test_invariants`, `test_allocation_budget` (replaced by a syntax allocation test pinning allocations per construct, so a compiler improvement shows as a decrease and a regression fails) |
| **M7** | Documentation: `DISCOVERY_TABLES_DESIGN.md` is replaced by this document's settled form; `ARCHITECTURE.md`, `DISCOVERY_ACCEPTANCE_ROADMAP.md` and `docs/README.md` are updated; the resolution design takes section 4.7. | `git diff --check`; link check | the superseded design text |

Ordering and parallelism:

- M1 begins by verifying the opaque-type import-cycle repro on its own base.
- M1 and M2 are independent of each other.
- M3 needs M1 and M2, M4 needs M3, and M5 needs M4.
- G2 (tuple hand-off, `VALUE_TUPLES_AND_STATE_HANDOFF.md`) proceeds in parallel. M1 to M5 do not wait on it; M6 does (its increments 1 to 4, and 5 if the re-measured M0 still needs it).

Syntax stays frozen from M1 through M4, so the differential compares against
a fixed target.

## 9. Open decisions

These recommendations are not acceptance decisions yet; sections 3–6 use
the proposed forms so their consequences can be reviewed.

- **D1. Decimal floats (5.2).** Recommend opaque `DecimalFloat` over a
  checked 64-bit `Float`: converting decimal directly to the selected width
  avoids double rounding for `Float32`. Lexing checks 64-bit finiteness;
  typecheck still rejects values overflowing the selected narrower width.
- **D3. Type-decided names (3.2, E8).** Recommend one `NameUse` family for
  record fields and dotted members, rather than a separate member family.
  `m.f` may be scope-decided and `x.f` type-decided; one ID per use keeps
  resolution's outcome discipline uniform.
- **D4. Legacy sigil order (6.2).** Recommend accepting normalized C identity
  if reordered `#N` names affect only ID-derived output names, rather than
  remembering legacy interleaving in discovery.

The M6 ceiling is decided and stays in section 7.3. Recovery, opaque minting,
per-module interning, tree output, ordinary-record syntax values, glue
ownership and resolution's binding responsibility are the proposal's settled
contracts in their owning sections, not a second decision inventory.
