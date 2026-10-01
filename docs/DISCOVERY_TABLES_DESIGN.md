# Discovery as Normalized Tables

This document describes how the discovery phase (lexing, parsing and module
loading) is rebuilt to produce normalized tables instead of parsed trees,
and how the old contract keeps working while later stages move over. It
began as a design sketch; sections 2 to 10 now describe the implemented
schema in `blorp/src/compiler_new/stage_01_discovery/`, and the code quoted
here is abbreviated from those files. Where this document and the source
disagree, the source and its tests win; fix this document in the same
change.

The plan it serves:

1. Rewrite discovery. An adapter between it and typecheck, in the
   compiler's pipeline, rebuilds today's `FrontendCompilationGraph` from the tables, so
   typecheck is unchanged.
2. Connect it: compilation runs the new stage and the adapter by default
   (`docs/DISCOVERY_ACCEPTANCE_ROADMAP.md` says when).
3. Rewrite typecheck to read the tables piece by piece, deleting the matching
   part of the adapter each time, until the adapter is gone.
4. Specify typecheck's own output as tables, and repeat for the next stage.

Three decisions were made up front: function bodies live in a flat node
table; `DefinitionId` is minted here, in discovery; spans are packed
integers.

## Layout

Read `pipeline.brp` first: it is the stage's order of work (roots, imports
breadth first, freeze) and `load_module`, one named step per call, and says
which folder owns each step's mechanics.

```
stage_01_discovery/
  pipeline.brp     discover and load_module: the order of work
  tables/          the data model every other part writes and reads
    builder.brp  diagnostic_code.brp  frontend_tables.brp  intern_index.brp
    invariants.brp  name_vocabulary.brp  row_kinds.brp  source_position.brp
    span.brp  token.brp
  sources/         which files make up the program
    embedded_standard_library.brp  module_graph.brp  source_admission.brp
    source_provider.brp
  lex/lexer.brp
  diagnostics/render.brp   the message and help of each diagnostic code
  parse/           parser_cursor, declaration_header, declaration_parser,
                   import_parser, type_parser, pattern_parser, body_parser
```

The tests mirror the folders under `blorp/test/compiler_new/stage_01_discovery/`
(`tables/`, `sources/`, `lex/`, `parse/`, with `lex/fixtures` and
`parse/fixtures`); `tools/` and `support/` sit beside them. `tables/` imports no other
folder; `sources/` and `lex/` import only `tables/`; `parse/` imports those
three; only `pipeline.brp` ties the steps together. `diagnostics/` imports
`tables/` and `sources/` (the text of an import that differs only in letter
case reuses the provider's respelling) and nothing imports it: it is read by
whatever shows diagnostics.

## Status

**Implemented** under `blorp/src/compiler_new/stage_01_discovery/`, isolated
from the existing compiler (it imports only `lib` and itself, which
`scripts/check-blorp-layout` enforces transitively), with its own gate
`scripts/test compiler-new` (part of the default gates, `premerge-gate` and
compiler CI):

- the builder, every row table below, and the table invariants `freeze`
  checks;
- the lexer, with token parity against the existing lexer over the whole
  corpus;
- the module graph (resolving requests) and the source providers (file
  system, in-memory and the embedded standard library), with the native and
  source package lookup rules;
- the implicit modules (section 6): `prelude` and `tuple`, and `test` when
  testing, loaded after the roots as the existing front end seeds them;
- the declaration, type, pattern and body parsers, with accept/reject parity
  against the existing parser over the corpus;
- the legacy adapter (section 10), declarations and bodies, proved by a
  full-AST differential over the corpus.

**Pending:**

- **The switch** (roadmap items 7 and 8). Nothing in a compile reads the
  tables yet.

## 1. Principles

**One owner of state.** Every table and every id belongs to one value, the
`DiscoveryBuilder`. It is passed into each step and returned updated. Nothing
else mints ids, so an id is always the index of its row.

**Rows are structs.** A row holds only scalars, payload-free enums, opaque
ids and nested structs, so a table is a `List` of rows stored inline: one
allocation per table, no allocation per row. Text lives in exactly four
tables: names, paths, source texts and literals.

**No optional fields, no variable-length fields.** An optional relationship
is the presence of a row in a side table. Variable-length data is a child
table whose rows are written as one contiguous block, which the parent row
addresses with a `RowRange`.

**Rows never travel inside unions.** A struct inside a union payload is
boxed, which is how an earlier struct conversion lost its gains. Anything
shaped like a tree refers to rows by id.

**Deterministic order.** Ids follow discovery order: roots first, then
imports breadth first in source order. Stable ids are what make the output
reproducible, which is what lets the adapter's output match the existing
discovery's.

## 2. Identities

Every table has its own opaque id over `Int`, so ids from different tables
cannot be mixed up. The constructors are private to `tables/builder.brp`.

```blorp
opaque type NameId = Int
opaque type SourceId = Int
opaque type PathId = Int
opaque type PackageId = Int
opaque type ModuleId = Int
opaque type RootId = Int
opaque type ImportId = Int
opaque type ImportItemId = Int
opaque type DefinitionId = Int
opaque type NodeId = Int
opaque type LiteralId = Int
opaque type ParameterId = Int
opaque type ForeignBlockId = Int
```

A span is one integer: the source index, then the start offset, then the
length (`tables/span.brp`). There is no `NO_SPAN`: every row that has a span has a
real one, and compiler-synthesized rows point at the syntax that caused
them.

| Field | Bits | Limit |
| --- | --- | --- |
| source index | 15 | 32,768 sources |
| start offset | 24 | 16 MiB per source |
| length | 24 | 16 MiB |

15 + 24 + 24 = 63 bits, so a span is a non-negative `Int`. Discovery admits
a source only when its index and byte length fit (`sources/source_admission.brp`);
a source that does not fit is reported with `SourceTooLargeDiagnostic` or
`TooManySourcesDiagnostic` and not parsed, so packing never loses
information.

## 3. Rows

Each table is a list of one struct type (`tables/builder.brp`); the
payload-free enums the rows store are in `tables/row_kinds.brp`.

### Sources, packages, modules and roots

```blorp
struct RowRange {first: Int, count: Int}

-- The text is `source_texts[source]`; line starts are a block of `line_starts`.
struct SourceRow {path: PathId, line_starts: RowRange}

struct PackageRow {name: NameId, kind: PackageKind}   -- NativePackage | SourcePackage

struct ModuleRow {
	source: SourceId,
	canonical_path: PathId,
	origin: ModuleOriginKind,   -- StdlibModule | PackageModule | SourcePackageModule | UserModule
	reach: ModuleReach,         -- RootModule | ImplicitModule | ImportedModule
	definitions: RowRange,
	imports: RowRange,
	nodes: RowRange,
	diagnostics: RowRange
}

struct ModulePackageRow {module: ModuleId, package: PackageId}

struct RootRow {request_path: PathId}
struct RootTargetRow {root: RootId, target: ModuleId}
struct RootDiagnosticRow {root: RootId, code: DiscoveryDiagnosticCode, arguments: RowRange}

struct ImplicitRequestRow {request_path: PathId}
struct ImplicitTargetRow {request: ImplicitRequestId, target: ModuleId}
struct ImplicitDiagnosticRow {request: ImplicitRequestId, code: DiscoveryDiagnosticCode, arguments: RowRange}
```

`ModuleReach` replaces the sketch's `is_root: Bool`. Each module's rows in
the definitions, imports, nodes and diagnostics tables are contiguous blocks,
closed when its parse ends. Every root has exactly one outcome: a
`RootTargetRow` or a `RootDiagnosticRow`. The implicit module requests (section
6) are a table of their own, not roots, with the same one-outcome rule
(`ImplicitTargetRow` or `ImplicitDiagnosticRow`).

### Imports

```blorp
enum ImportRequestKind:
	BareModuleRequest       -- `heap`, `lib/source`: the provider decides where it resolves
	RelativeModuleRequest   -- `./x`, `../x`
	NativePackageRequest    -- `pkg/<package>/...`

struct ImportRow {
	importer: ModuleId,
	request_kind: ImportRequestKind,
	request_path: PathId,       -- the import syntax, kept as text on purpose
	parent_steps: Int,          -- leading `../` (0 for `./` and non-relative)
	path_parts: RowRange,       -- into import_path_parts: List[NameId]
	items: RowRange,            -- into import_items
	path_span: Span,            -- the module path alone
	span: Span                  -- through the last selected symbol, else the alias or path
}

struct ImportItemRow {owner_import: ImportId, name: NameId, variants: RowRange, name_span: Span, span: Span}
struct ImportItemVariantRow {item: ImportItemId, name: NameId, span: Span}
struct ImportBlockRow {module: ModuleId, imports: RowRange, span: Span}

-- Optional relationships: at most one row per owner.
struct ImportTargetRow {owner_import: ImportId, target: ModuleId}
struct ImportAliasRow {owner_import: ImportId, alias_name: NameId, span: Span}
struct ImportItemAliasRow {item: ImportItemId, alias_name: NameId, span: Span}
-- The docstring that opens a module, directly before its first `import:` block.
struct ModuleDocumentationRow {module: ModuleId, text: LiteralId, span: Span}
```

The sketch's "stdlib request" became `BareModuleRequest`: the syntax does
not decide whether a bare path is a standard-library module, a source
package or a local file; the provider's lookup policy does. Resolution reads
the structured form (`parent_steps`, `path_parts`), never the request text.

### Definitions

```blorp
enum DefinitionKind:
	FunctionDefinition
	RecordDefinition
	StructDefinition
	UnionDefinition
	EnumDefinition
	BuiltinTypeDefinition
	ResourceTypeDefinition
	TypeAliasDefinition
	OpaqueTypeDefinition
	TraitDefinition
	ImplDefinition
	ConstantDefinition
	MutableGlobalDefinition
	ForeignFunctionDefinition
	FieldDefinition
	VariantDefinition
	TraitMethodDefinition
	ImplMethodDefinition
	LocalFunctionDefinition

struct DefinitionRow {
	module: ModuleId,
	kind: DefinitionKind,
	name: NameId,
	name_span: Span,
	visibility: Visibility,
	span: Span             -- from the docstring, annotations or `pure`, when present
}

struct MemberRow {definition: DefinitionId, owner: DefinitionId, ordinal: Int}
```

Impls have no name of their own, so their name columns hold the implemented
trait's name. The sketch's `TestDefinition` is gone: the language has no test
declaration, so tests are ordinary functions. A `LocalFunctionDefinition` is a
function declared inside a body; its body node is a `LocalFunctionNode`
whose payload is the definition's id, and its signature and body are
ordinary signature and body rows.

What comes before a declaration's keyword is read into a
`DeclarationHeader` (`parse/declaration_header.brp`), a plain struct, so a header
costs no allocation:

```blorp
struct DeclarationHeader {
	module: ModuleId,
	start: Span,
	visibility: Visibility,
	purity: Purity,
	docstring: RowRange,     -- 0 or 1 rows of the transient pending_docstrings
	annotations: RowRange    -- a block of the transient pending_annotations
}
```

The docstring and annotations are read before the definition's id exists,
so they wait in transient tables; `close_definition` copies them into
`documentation` and `annotations` once it does.

### Signatures, parameters and types

```blorp
-- Exactly one per function-like definition.
struct SignatureRow {definition: DefinitionId, purity: Purity, keyword_span: Span, parameters: RowRange}

struct ParameterRow {
	owner: DefinitionId,
	ordinal: Int,
	binder: ParameterBinder,    -- NamedParameterBinder | WildcardParameterBinder | TupleParameterBinder
	binder_names: RowRange,     -- one name, none for `_`, two to four for a tuple
	binder_span: Span,
	span: Span
}
struct BinderNameRow {name: NameId, span: Span}

-- Written types are node trees (section 3, Nodes); these rows name their roots.
struct ParameterTypeRow {parameter: ParameterId, type_root: NodeId}
struct DefinitionTypeRow {definition: DefinitionId, type_root: NodeId}
struct VariantPayloadRow {variant: DefinitionId, ordinal: Int, type_root: NodeId}

struct TypeParameterRow {owner: DefinitionId, ordinal: Int, name: NameId, kind: TypeParameterKind, name_span: Span, span: Span}
-- TypeParameterKind: TypeParameter | DimensionParameter | WildcardDimensionParameter

-- `name_span` covers the name alone, `span` the whole row (the type parameter
-- with its bounds; the reference with its module alias).
struct BoundRow {owner: DefinitionId, parameter_ordinal: Int, trait_name: NameId, name_span: Span, span: Span}
struct SupertraitRow {trait_definition: DefinitionId, ordinal: Int, name: NameId, name_span: Span, span: Span}
-- Optional relationships (one row per bound or supertrait id, at most): the
-- `alias` of `alias.Trait`. The bound's or supertrait's own span covers the
-- whole reference; the qualifier row's span covers the alias.
struct BoundQualifierRow {bound: BoundId, qualifier: NameId, span: Span}
struct SupertraitQualifierRow {supertrait: SupertraitId, qualifier: NameId, span: Span}
struct DimensionConstraintRow {owner: DefinitionId, left: NodeId, right: NodeId, span: Span}
```

A node whose name is narrower than the node has a
`NodeNameSpanRow {node, name_span}`, at most one per node, in node order:
for a written type, `List[T]`, `m.Type`, `T: Eq`, `#Ds...` and a trait bound
through a module alias; for a body, the field of `x.field` and of a record
field, the target a binding, assignment, `?=` or compound assignment binds, a
`with` or `on` binder, a select arm's binder, a concurrency parameter, a typed
lambda parameter, the constructor of `Name(p)` and `Type.Name(p)`, and the
target of a list pattern's spread (`...rest`, `..._`). `node_name_span` reads
a node's name span, which is the node's own span when it has no row. The
existing parsed AST has an identifier, with a span, where the tables have a
name, and the adapter may not reconstruct a span the tables lack. The
`else` keyword of an `if` is the one other span a node cannot give: neither
branch covers it and the formatter places comments around it, so an `IfNode`
with an else branch (a third child) has an `ElseKeywordRow {node,
keyword_span}`, at most one per node, in node order.

A `DefinitionTypeRow`'s role is fixed by the definition's kind: a
function's return type, a global's declared type, an alias's or opaque
type's target, an impl's receiver, a field's type. A bound is one trait
name (`BoundRow.trait_name`) with an optional module alias: `T: alias.Trait` is
legal, and the alias is the bound's `BoundQualifierRow`, the way an optional
relation is a side table, rather than a sentinel `NameId` in the bound row. The
same holds for supertraits. A bound inside a written type (`Box[T: alias.Trait]`)
is a node: `TypeBoundNode`, or `QualifiedTypeBoundNode` over a
`TypeQualifierNode`, as a qualified type has. The two differ because rows use
side tables for optional relations, while a written type is a node tree whose
qualified forms are sibling node kinds with a qualifier child. Typecheck resolves the alias as a
qualified type's qualifier and then finds the trait among that module's
declarations.

### Documentation, annotations and foreign declarations

```blorp
struct DocumentationRow {definition: DefinitionId, text: LiteralId}
struct AnnotationRow {definition: DefinitionId, annotation: FunctionAnnotation, span: Span}
-- FunctionAnnotation: TailRecursive | NoCopy | DebugOnly | ResourceResultOrdinary

struct ForeignBlockRow {module: ModuleId, arguments: RowRange, span: Span}
struct ForeignArgumentRow {name: NameId, value: LiteralId, name_span: Span, span: Span}   -- `include: "x.h"`, ...
struct ForeignBindingRow {definition: DefinitionId, block: ForeignBlockId}
struct ForeignCNameRow {definition: DefinitionId, c_name: LiteralId, span: Span}
struct ResourceCleanupRow {definition: DefinitionId, builtin_name: LiteralId, span: Span}

struct BodyRow {definition: DefinitionId, root: NodeId}
```

Foreign blocks store their arguments as generic rows rather than the
sketch's `includes`/`links` columns, so a new block argument needs no schema
change.

### Nodes

Bodies, patterns and written types share one flat node table. Each node is a
small row: its kind, its span, one integer payload whose meaning the kind
fixes, and a block of child edges.

```blorp
struct NodeRow {kind: NodeKind, span: Span, payload: Int, children: RowRange}
-- node_children: List[NodeId]; a node's children are one block of it.
```

**`tables/row_kinds.brp` is the single source for the node kinds.** Its
`node_schema(kind)` declares each kind's shape once, with no wildcard arm, so a
new kind does not compile until it is described: the table its payload indexes
(`NamePayload`, `LiteralPayload`, `CodepointPayload`, `DefinitionPayload` or
`NoPayload`, which stores `NO_NODE_PAYLOAD`), its `ChildArity` and its
`NameSpanRule`. A comment beside each arm gives the child order. The freeze
checks read the schema. This document does not repeat the list. There are 127
kinds in these families:

- literals and names: `IdentifierNode`, one kind per literal form (integer,
  float, string, raw, pipe, raw pipe, char, `True`, `False`), and the
  interpolated forms below;
- operators: one kind per unary and binary operator (`AddNode`,
  `LessEqualNode`, `AndNode`, ...), plus `RangeNode`;
- calls and access: `CallNode`, `FieldAccessNode`, `SubscriptNode`;
- aggregates: list, tuple, vector, record literal and update, record field,
  dict literal and entry, `into_opaque` and `from_opaque`;
- control flow: block, `if`, `match` and its cases, `select` and its arms,
  `with` and its bindings, `debug:`, lambdas, local functions, loops,
  concurrency, `break`, `continue`;
- statements: `var`, typed binding, assignment, `?=`, the four compound
  assignments, subscript assignment, tuple destructuring;
- patterns: `...PatternNode` kinds, which appear only where a pattern was
  written; a string pattern has one kind per form (plain, raw, pipe, raw
  pipe), as a string literal does, because the existing AST records the form;
- written types: `...TypeNode` kinds, including dimension names, literals,
  wildcards and arithmetic, which appear only where a type was written;
- recovery: `MissingExpressionNode`, `MissingPatternNode`,
  `MissingTypeNode`, each with a diagnostic row.

The sketch's kinds that were removed:

- **`BinaryNode` and `LiteralNode`.** An operator or literal form is its own
  kind, so readers match on the kind instead of decoding a payload, and the
  payload is always one of the typed references above.
- **`TupleIndexNode`.** The language has no numeric field access (`t.0`
  is a syntax error in both parsers), so every field access is a
  `FieldAccessNode` with a name payload.
- **The match guard.** The language has no guards; a `MatchCaseNode` has a
  pattern and a body.

A child documented as "when written" (an optional type, an `else` branch) is
recognized by its kind, never by position alone. Grouping parentheses add no
node: they widen the enclosed expression's span to the delimiters, except for a
name and a local function, whose spans stay token-exact because rename and
reference tooling edits those tokens (the existing parser does the same). A compound assignment
(`x += 1`) has only the value child: it has no written type.

**Named arguments.** `f(a = 1)` parses as a `CallNode` whose argument is an
`AssignmentNode` with the parameter's name as its payload. The identifier
leaf parsed before the parser sees `=` is discarded, so no node is
orphaned; the invariants check that every node is referenced exactly once.

**Interpolation.** An interpolated string is an `InterpolatedStringNode` (or
`InterpolatedPipeStringNode`) whose children are, in source order,
`InterpolationTextNode` pieces (payload: the `LiteralId` of the decoded
text) and `InterpolationHoleNode` holes, each spanning its `$` through its
`}` with the hole's expression as its one child. The hole node gives the
hole an extent of its own, apart from its expression's: Core lowering uses
it as the node id of the call that converts the value to text. A text
piece is present before, between and after holes when it is non-empty. The
lexer finds the pieces and hole byte ranges once, while lexing the string
(section 7); the parser never rescans the string. Text pieces hold decoded text (escapes applied, as in a plain
string literal) and never hole source text. The existing compiler encodes
an interpolated string in-band as one literal with `{...}` marking holes and
does not escape braces in the text before the first hole, so
`"a {b} ${c}"` reports `b` as unbound; with separate text and hole children
that ambiguity cannot arise. An interpolated string written as a pattern is
rejected with `InterpolatedStringPatternDiagnostic`.

### Diagnostics

```blorp
struct DiagnosticRow {code: DiscoveryDiagnosticCode, span: Span, arguments: RowRange}
-- diagnostic_arguments: List[Int] (ids or counts, by code)
```

`diagnostics` holds each module's lex and parse diagnostics in the module's
contiguous block; `resolution_diagnostics` holds the module graph's (imports that
loaded nothing, sources that could not be admitted). The code catalogue is
`tables/diagnostic_code.brp`: 105 codes, each documented with the meaning
of its arguments, and `diagnostic_code_name` gives the stable names dumps
and fixtures use. Messages are rendered from the code and arguments at the
boundary that shows them, so the text lives in one place and can be tested
exactly.

### Diagnostic text

`diagnostics/render.brp` is that one place:

```blorp
record RenderedDiagnostic {message: String, help: Option[String]}
pure func render_diagnostic(tables: FrontendTables, row: DiagnosticRow) -> RenderedDiagnostic
pure func render_root_diagnostic(tables: FrontendTables, row: RootDiagnosticRow) -> RenderedDiagnostic
pure func diagnostic_display(tables: FrontendTables, row: DiagnosticRow) -> String
```

`diagnostic_display` prints `path:line:column: error: message` and, on its own
line, `help: ...`: the shape the existing compiler prints, with the same column
convention (bytes, a tab advancing to the next multiple of four). One `match`
over the code supplies the text, so a code without text does not compile, and
every code has a help line (a test walks the code list). Arguments are
spelled from the frozen tables: an import's text, a literal's digits, the
stored name of a differently-cased file, and the names a parser interned (a
reserved keyword written as a name, an unknown annotation, a concurrency
parameter). Only `UnexpectedCharacter`, which has no token to name, reads the
source text under its span.

Each code documents its arguments as data: `diagnostic_argument_kinds(code)`
in `diagnostic_code.brp` lists their kinds (a construct, an import, a path, a
literal, a name, a number). `freeze` rejects a row with another number of
arguments (`ArgumentCountMismatch`) or an invalid one, a construct that
decodes to none or an id with no row (`ArgumentOutOfRange`), so rendering
reads exactly what the code documents and has no missing-argument case. The 14
`Expected...` codes can be reported only with a construct: a parser that
reports one through the plain `report_at_current` or `expect_token` helpers
(which store no argument) produces a row `freeze` rejects, so the mistake
fails every fixture and gate at once. (Splitting the code type so the plain
helpers cannot accept them would duplicate every other code's name; the
freeze check is the smallest explicit option.)

The text is copied from the existing compiler, not referenced, and is pinned
twice. Every `should_fail` fixture that pins a first diagnostic also pins the
existing compiler's text (`-- EXPECT-BLORP:` lines, run by the existing
compiler's fixture runner) and position (`-- EXPECT-BLORP-CONTAINS:`), and the
fixture suite requires the stage to display exactly that. Where the stage
words a diagnostic differently on purpose the fixture says so in
`-- EXPECT-DISCOVERY-TEXT:` lines (and `-- DISCOVERY-POSITION-DIFFERS:` for a
position), which fail once they stop differing. The corpus parity gate compares
the first diagnostic of every file both front ends reject the same way, with
the differences below as a reasoned allow-list.

The 14 `Expected...` codes for a missing token (`ExpectedColon`,
`ExpectedRightParen`, `ExpectedName`, ...) carry one argument, the
`ParsedConstruct` the parser was in (`row_kinds.brp`: `IfCondition`,
`Subscript`, `FunctionParameters`, ...), so `render.brp` can say `expected `:`
after if condition` and not only that a colon is missing. A construct is
meaningful only with the codes that report it; any other combination, or a
row without the argument, reads as the code's general text (`expected `:``).
`UnionVariantTooManyFields` carries its limit the same way, so the number
lives only in the parser.

Of the 94 codes the fixtures pin, 36 print exactly the existing compiler's
text (message and help); 52 print the existing message and add a help line; 6
word the message differently on purpose. `ImportCaseMismatch` (no
single-module fixture can reach it) also prints exactly the existing text,
pinned in `test_render.brp`. The other 10 codes had no existing diagnostic worth
copying.

| Class | Codes | Existing text | Stage text | Why |
| --- | --- | --- | --- | --- |
| Help added (52) | `ExpectedAliasName`, `ExpectedArrow`, `ExpectedAssignmentOperator`, `ExpectedClosingParenAfterConstructors`, `ExpectedColon`, `ExpectedColonAfterImport`, `ExpectedComma`, `ExpectedCommaBetweenImportSymbols`, `ExpectedConstructorName`, `ExpectedDimension`, `ExpectedEqual`, `ExpectedEqualEqual`, `ExpectedExpression`, `ExpectedFatArrow`, `ExpectedHash`, `ExpectedImportSymbol`, `ExpectedImportSymbolsAfterColon`, `ExpectedKeyword`, `ExpectedLeftBrace`, `ExpectedModulePath`, `ExpectedName`, `ExpectedNewline`, `ExpectedNewlineAfterImportHeader`, `ExpectedNumberAfterMinus`, `ExpectedPattern`, `ExpectedRightBrace`, `ExpectedRightBracket`, `ExpectedRightParen`, `ExpectedSpreadTarget`, `ExpectedSupertraitOrMethods`, `ExpectedType`, `InconsistentIndentation`, `IntegerLiteralOverflow`, `InterpolatedEscapeAtEnd`, `InterpolationTooDeep`, `InvalidCharLiteral`, `MultilineInterpolatedString`, `MultilineRawString`, `MultilineString`, `TupleArity`, `UnexpectedCharacter`, `UnicodeCodepointOutOfRange`, `UnicodeEscapeDigitCount`, `UnicodeEscapeNonHex`, `UnknownEscape`, `UnterminatedCharLiteral`, `UnterminatedDocstring`, `UnterminatedEscape`, `UnterminatedInterpolatedString`, `UnterminatedRawString`, `UnterminatedString`, `UnterminatedUnicodeEscape` | the message, no help line (the 14 construct codes: the construct-specific message) | the same message and a help line | every error teaches (rule 6 of `AGENTS.md`) |
| Advice moved to help (3) | `ReservedKeywordAsName`, `DiscardedQuestionBind`, `FieldAssignment` | the advice follows the problem in the message (`...; choose another identifier such as `from_name``) | the problem in the message, the advice in the help line | one idea per line; the same words |
| Poor existing text (3) | `ExpectedIndentedImports`, `ExpectedIndent` (a union's variants), `InterpolationHoleNotExpression` | `expected indented function body` for a bare `import:` and for a union with unindented variants; `Parse error in interpolated expression: expected `=` after top-level variable declaration` | `expected indented imports after `import:``, `expected indented variants`; `an interpolation hole must hold exactly one expression` | the existing text names the wrong construct, or an internal parse step |
| No existing equivalent (10) | `UnresolvedImport`, `UnresolvedRoot`, `RootCaseMismatch`, `UnverifiableSpelling`, `UnverifiableRootSpelling`, `UnreadableSource`, `UnreadableRootSource`, `SourceTooLarge`, `TooManySources`, `UnexpectedByte` | `module 'x' is not loaded for import registration` for an unresolved import; an invalid byte was printed raw; the others were not diagnosed this way | new text with help; the argument is rendered (the import's text, the file's path, the byte as `0xFF`, the length) | the existing text is an internal step or absent |

Where the existing parser had one text for several constructs, the stage has
a general one: a missing indent after any block header reads `expected an
indented block` (the existing `expected indented function body` is right only
for functions), and the `Expected...` codes keep the existing `, ` (comma and
space) token spelling of `expected `, ` between ...`. `UnexpectedCharacter`
also spells a character a quote would hide as `U+XXXX` (the existing compiler
printed a carriage return or a zero-width space raw).

Positions agree with the existing compiler for every fixture and every corpus
file except two, listed with their reasons in `scripts/compiler-new-parity`
and in the fixtures (`import_constructors_unclosed`,
`interpolation_hole_two_expressions`).

## 4. The builder

The builder is a flat record whose fields are the tables. Keeping it flat
matters: every level of nesting is one more uniqueness check a copy-on-write
update must pass. Besides the row tables above it holds the text tables and
their intern indexes (`name_spellings`/`name_slots`,
`literals`/`literal_slots`, `paths`/`path_ids_by_text`), `source_texts`,
`line_starts`, and `module_ids_by_path`.

### How ids are minted without copying

An id is the row's index, so the caller reads the next id before appending.
No function returns `(builder, id)` pairs, because destructuring them is one
of the shapes that has produced copies.

```blorp
definition: DefinitionId = next_definition_id(builder)
builder = append_definition(builder, row)
```

### Threading rules

Every table must stay uniquely referenced so each append grows its list in
place. When the compiler cannot see that a builder is handed on at its last
use, it keeps a second reference, and the next update copies the builder and
every table appended to while the old one lives: an O(n) copy per append.
The canonical statement of the seven rules that avoid this is the header of
`tables/builder.brp`; each site that depends on one cites it by number.
In short: the first update of a builder parameter is unconditional; no tail
call on a reassigned `var`; the builder is not read in another argument of
the call it is handed to; no `f(g(b))`; in loops `out = f(out)`, never
through temporaries; a record update's field value reads only that field;
no aliasing, storing or capturing.

`tables/test_allocation_budget.brp` in the compiler-new gate parses a repeated
source and fails when allocations exceed a fixed budget, so breaking a rule
fails the gate rather than only slowing the compiler.

### Transient builder state

The sketch advised keeping tokens and similar per-module data in locals.
The implementation reverses that: lexing interns names and literals into
the builder while it produces tokens, and parsing appends rows while it
consumes them, so the builder is the only value threaded through that work.
A second value threaded beside it would double every signature and every
chance to break a threading rule. The transient fields are:

- `tokens`, `token_cursor`: the module being parsed, with its interpolation
  holes' tokens appended after its end-of-file token;
- `pending_docstrings`, `pending_annotations`: read before their
  declaration's row exists;
- `interpolations`, `interpolation_parts`, `interpolation_texts`: the
  module's interpolated strings (section 7);
- `child_stack`, `child_stack_depth`: node roots a parent has not yet
  claimed.

`without_transient_tables` empties them; lexing a module starts from it, and
`freeze` drops them with it.

### Post-order nodes through the child stack

A recursive-descent parser cannot keep a node's children next to each other
in the node table: while it parses the first child, that child's own
children are appended in between. So children live in the `node_children`
edge table, and a node is appended only after its children are finished.
Each parsed child is pushed on the child stack (`push_last_node`); the
parent is appended with `append_parent_node_from_stack(b, kind, span,
count)`, which moves the top `count` entries into one contiguous block of
`node_children`. A parent's row is written exactly once, and no local list
of child ids is allocated.

Nodes are appended only through typed appenders, one per payload class, so
a payload is always what its kind says:

| Appender | Payload |
| --- | --- |
| `append_leaf_node`, `append_parent_node`, `append_parent_node_from_stack` | none |
| `append_name_leaf_node`, `append_named_parent_node`, `append_named_parent_node_from_stack` | `NameId` |
| `append_literal_leaf_node` | `LiteralId` |
| `append_codepoint_leaf_node` | a Unicode scalar value |
| `append_definition_leaf_node` | `DefinitionId` |

### Speculative parses

One construct needs a speculative parse: `into Type(...)`, the removed
spelling of `into_opaque Type(...)`, is reported with a migration diagnostic
only when it parses as that form, since `into` is otherwise an ordinary
name. `parse_checkpoint`
records the token cursor, the node, edge, diagnostic and diagnostic-argument
table lengths, and the child stack depth in a `ParseCheckpoint`;
`rollback_to` truncates back to them. A speculative parse must not intern:
the checkpoint also records the name and literal counts, and a debug build
reports an error at rollback if either changed.

### Interning

Names and literals are interned through an open-addressing slot table
(`tables/intern_index.brp`): one `List[Int]` of (row, hash) entries, at least twice
as many slots as rows, searchable by a slice of the source text without
allocating the slice. An identifier that is already interned costs no string
at all. The hash is FNV-style mixing finished with MurmurHash3's 64-bit
finalizer; over the self-compile the average probe length is 1.44 for names
and 1.26 for literals. Frozen tables keep the indexes, so readers can look a
spelling up.

Every name table starts with the seeded vocabulary (`tables/name_vocabulary.brp`)
at pinned ids: a copy of the existing compiler's synthesized vocabulary, in
the same order, all 236 of them, so the adapter hands the existing compiler's
later phases a table whose ids agree with the `NAME_ID_*` constants they
compare against; then the spellings only discovery compares (`tail_recursive`,
`no_copy`, `debug_only`, `resource_result_ordinary`, `into`, `max_threads`).
The parser compares annotation names and the removed conversion by `NameId`,
never by spelling. The lexer also interns `#N` beside the plain `N` it
records for a dimension name, as the existing lexer does, and writes a
`DimensionNameRow {name, sigil_name}` pairing them; `freeze` checks the pairing
spells `#` and the name (`SigilSpellingMismatch`) and that every dimension name
has a row (`DimensionSigilNameMissing`).

### The probe that came first

Before the parser was written, `blorp/test/compiler_new/tools/builder_append_probe.brp`
appended rows to the definitions, nodes, edges and names tables in each
calling shape and read them back. Allocations beyond the baseline (which
builds the name spellings) at 10k / 100k / 1M rows:

| Shape | Extra allocations |
| --- | --- |
| loop, helpers, recursive chains, reads | 55 / 71 / 86 |
| post-order tree (the parser's shape) | 31 / 37 / 43 |

That is list growth only, logarithmic in the row count, with no per-append
copy. The fallback the sketch named (per-module local tables appended in
bulk) was not needed.

## 5. The source provider

Reading files is discovery's only effect. It sits behind one two-call trait
(`sources/source_provider.brp`), so the rest of the phase is pure and an editor can
serve unsaved buffers:

```blorp
union SourceRead:
	SourceText(String)
	SourceUnreadable

trait SourceProvider:
	func source_exists(self: Self, path: String) -> Bool
	func read_source(self: Self, path: String) -> SourceRead
```

Everything else is a pure lookup policy shared by every provider:
`import_candidates` lists the paths an `ImportRequest` may resolve to, in
the order they are tried, each with the `ModulePlacement` the module there
would have (standard library, native package, source package or user code;
the origin and the package row both come from it); the first that exists wins.
The order is language behavior and is the existing front end's
`frontend_import_lookup_plan`: a bare request from user code or a native
package module tries a source package alias (exported modules only), then
the standard library, then the importer's directory; from a source package
module its own modules, then the standard library; from the standard library
only the standard library. Relative requests keep the importer's placement,
and a source package module's stay under the package's `source_dir`. `pkg/`
requests resolve from user code and native package modules, not from the
standard library or a source package. Keeping the policy out of the provider
is what makes an editor resolve exactly like a build.

Implemented providers: `FileSystemSourceProvider` and
`InMemorySourceProvider` (tests and overlays), and
`EmbeddedStandardLibraryProvider` (`sources/embedded_standard_library.brp`),
which answers for paths under `EMBEDDED_STANDARD_LIBRARY_ROOT` from the texts
embedded in the compiler and leaves every other path to the provider it wraps.
It lists directories from the embedded module names, so the exact-case check
works below the root. The embedded texts are a build input generated into
`compiler/stage_01_generated_inputs/embedded_std`, which the stage must not
import, so the provider asks for them through the
`EmbeddedStandardLibraryTexts` trait and the composition outside the stage
(the legacy adapter, the parity tools) implements it over
`embedded_std_module_names` and `embedded_std_source`. The stage's paths for
embedded modules are `<embedded-std>/<name>.brp`; the existing front end's
`<embedded:name>` is `embedded_module_name` plus a spelling, derived by the
consumer rather than stored twice. The package catalog supplies
`native_package_roots` and `source_packages` (`SourcePackageRoot`: alias,
package name, source directory and exports) in `SourceLookupRoots`; neither
changes the module graph.

The existing front end names a module by how it was requested, so one source
package file reached both by its bare internal name and by a relative path is
two modules there and one here (the stage identifies a module by its path).
The parity fixtures avoid reaching a file both ways; the adapter must not
assume the old duplicates.

A native package module resolves bare and `pkg/` requests like user code, as
the existing front end does (a module it finds beside itself is user code,
not package code). The Guide's "bare imports resolve local or standard-library
modules" agrees, and no module under `pkg/` relies on anything else today.

## 6. The pipeline and the module graph

`pipeline.brp` is the stage's only loop over modules:

```blorp
func discover[Provider: SourceProvider](
	provider: Provider,
	lookup: SourceLookupRoots,
	roots: List[String],
	implicit: ImplicitModules,
) -> FreezeOutcome
```

Roots are loaded in the order given, then the implicit modules in the order
given, then every import in the order its module was loaded and, within a
module, in source order (breadth first). A module is loaded once per
canonical path, whichever request reaches it first, so ids depend only on the
roots, the implicit modules and the sources.

The implicit modules are the standard-library modules every compilation loads
without an import. The existing front end seeds `prelude` and `tuple`
(`COMPILER_FRONTEND_IMPLICIT_MODULE_PATHS`) and, for `blorp test`, `test`
(`TEST_RUNTIME_MODULE`), right after the roots, so the stage does the same, in
the same position, and module order equals the existing graph's (checked on the
self-compile: same modules, identical order). Everything else the prelude uses
(`option`, `result`, `range`, ...) arrives through these modules' own imports.
`pipeline` restates the names as `compiler_implicit_modules` and
`test_implicit_modules` because the stage must not import the old compiler.
A seed is a request of its own (`RequestedImplicitly`), not a root, with its
own request, target and diagnostic rows, and a module it loads has reach
`ImplicitModule` so later stages can tell it was not imported. It resolves as a
standard-library module under `lookup.standard_library_root`. A root that is
already that module (by canonical path) is the module the request targets, as
in the existing front end, and keeps reach `RootModule`; a seed with no source
is a `MissingImplicitModuleDiagnostic` row.

`scripts/compiler-new-parity` keeps the restated names honest: for the
self-compile root and for a `blorp test` root it compares the existing graph's
module sequence and origins (`legacy_module_order_dump.brp`) with the stage's
(`discovery_module_order_dump.brp`), so a change to the old constants fails
the gate. The same roots run with the standard library read from the embedded
texts, and a fixture project runs with two source packages and a native one.

Follow-up: roots and implicit requests have parallel request, target and
diagnostic tables and near-identical failure reporting in `module_graph`;
unify them into one requests table keyed by what asked (root or implicit) when
a third kind of request appears or the adapter reads them.

Roots and imports go through the same two steps. `sources/module_graph.brp`
resolves the request: `resolve_root` or `resolve_import` looks its candidates
up through the provider and answers with a `RequestResolution` (load this
source, reuse the module already loaded from that path, or why nothing can
be loaded). `pipeline.brp` carries the answer out: `load_module` admits the
source, opens the module's row, lexes, parses its declarations and closes the
row's ranges over the rows that were appended, then `record_target` or
`report_failure` records the outcome against the root or import. Each root
gets a target or a root diagnostic (`UnresolvedRootDiagnostic`,
`UnreadableSourceDiagnostic`); each import a target or an
`UnresolvedImportDiagnostic` resolution row. Discovery always goes on.

The loop's state besides the builder is two values of its own: the directory
listings the spelling checks have read (each directory is listed once per
discovery) and the `ImportQueue` of imports waiting to be resolved. Neither
holds the builder, so the builder threading rules (section 4) stay with the
builder.

## 7. Lexing

`lex_source(builder, source)` fills the transient `tokens` table and interns
every identifier, number and string into the builder as it goes. Tokens are
dropped when the next module's lexing starts.

```blorp
struct Token {kind: TokenKind, span: Span, payload: Int}
```

`tables/token.brp` documents each kind's payload. Two differ from the existing
lexer:

- **`DimensionNameToken`.** An identifier written directly after `#` (as in
  `#N`) is one token whose payload is the plain name's `NameId`, so
  adjacency is a lexer fact rather than a parser check on token positions.
  A `#` followed by anything else is a `HashSymbol`. This makes `# N` (with
  a blank) a syntax error; the existing parser accepted it, and nothing in
  the corpus uses it. The adapter reads the old `#N` spelling from the
  dimension name row the lexer wrote beside `N` when it rebuilds the
  existing compiler's identifiers.
- **`InterpolatedStringToken`.** The payload is the string's row in the
  transient `interpolations` table, a block of `interpolation_parts`:

  ```blorp
  enum InterpolationPart:
  	TextPart
  	HolePart

  struct InterpolationPartRow {part: InterpolationPart, start: Int, end: Int, text: RowRange}
  ```

  `start .. end` are the piece's source bytes; a text part's decoded text is
  one row of `interpolation_texts`. The parser lexes each hole's byte range
  with `lex_interpolation_hole`, which appends its tokens after the module's
  end of file, and parses it into the same tables with the same name table,
  so hole ids need no reconciling.

## 8. Parsing

The parser reads tokens and writes rows directly; there is no intermediate
syntax tree. `parse_module_declarations(builder, module)` parses
declarations, import blocks and foreign blocks; the type, pattern and body
parsers write node trees. Every routine follows the threading rules, so a
routine that branches before its first update does so in a helper whose
arms each call on the parameter.

What was a separate finalization pass is part of parsing: interpolation
holes are parsed where they appear; subscripts and compiler-owned import
forms are written in their final form; a named argument is an
`AssignmentNode` child of its call.

Binary operators have one source of truth: `binary_operator(token)` maps a
token to a `BinaryOperator` (or none), and `operator_precedence` and
`operator_node_kind` are total over that enum, so there is no default arm
and no sentinel precedence.

## 9. Freezing

When the last module is loaded, the builder is sealed:

```blorp
opaque type FrontendTables = DiscoveryBuilder

union FreezeOutcome:
	FrozenTables(FrontendTables)
	TableInvariantsViolated(List[TableInvariantViolation])

pure func freeze(builder: DiscoveryBuilder) -> FreezeOutcome
```

`freeze` always checks the invariants (`tables/invariants.brp`); there is no
trusted mode. The check reads each row a bounded number of times and
reports every violation as a `TableInvariantViolation {kind, table, row,
related_table, value}`, not only the first. `tables/frontend_tables.brp` exposes
read-only accessors; side tables read by owner are found by binary search,
which the sorted-by-owner invariant makes valid, and import items are
addressed by `ImportItemId`.

The invariants, by violation kind:

- `DanglingReference`, `RangeOutOfBounds`: every stored id names an
  existing row of the right table; every range lies inside its table.
- `ModuleRangesOverlap`: each module's blocks are disjoint from other
  modules'.
- `NodeChildNotBeforeParent`: every child was appended before its parent.
- `UnreferencedNode`, `NodeReferencedTwice`: every node is exactly one
  node's child or one row's root (body, parameter or definition type,
  variant payload, dimension constraint side).
- `NodeArityMismatch`: each node has a child count its kind's `ChildArity`
  allows.
- `PayloadOutOfRange`: each node's payload is valid for its kind's
  `node_schema` payload (a scalar value for a codepoint, `NO_NODE_PAYLOAD`
  for `NoPayload`); references are checked by `DanglingReference`.
- `LocalFunctionNodeMismatch`: a `LocalFunctionNode` names a local
  function definition.
- `BodyRootOutsideModule`: a body's root lies in its module's node block.
- `DuplicateSideRow`: at most one import target, import alias, root target,
  module package, definition type, body, bound qualifier or supertrait
  qualifier per owner.
- `RootOutcomeMismatch`: each root has exactly one of a target and a root
  diagnostic.
- `SignatureCountMismatch`: exactly one signature per function-like
  definition and none for others.
- `SideTableUnsorted`: side tables read by owner are strictly sorted by
  owner.
- `SpanOutsideSources`, `SpanPastSourceEnd`: every span names a source and
  ends within its text.
- `NameSpanOutsideItsSpan`, `NameSpanOnWrongNodeKind`: a name's span lies
  inside the span of what it names a part of, and a node name span row names a
  node of a kind that has one. `NodeNameSpanMissing` requires a row for a kind whose
  name is always narrower than the node (`needs_name_span_row`): types as above,
  and for bodies fields, binding and assignment targets, binders, constructor
  patterns and spreads. The parser records the row for every such node, so
  recovery cannot leave one out; only an untyped lambda parameter, which is its
  name alone, has none;
- `ElseKeywordMismatch`: an `ElseKeywordRow` belongs to an `IfNode` with an else
  branch and lies inside it, and every such `IfNode` has one.
- `DimensionSigilNameMissing`: every dimension name has its `#` spelling.
- `SeededNameMoved`: the seeded vocabulary sits at its pinned ids.
- `InternIndexMismatch`, `ParallelTableMismatch`: the intern indexes agree
  with their tables, and parallel tables have equal lengths.

`tables/test_invariants.brp` has a negative test per kind and per node
payload class.

## 10. The legacy adapter

The adapter is `blorp/src/compiler/discovery_adapter.brp`, the one module in
`compiler` allowed to import `compiler_new` (named in
`temporary_cross_owner_imports` of `blorp/source_ownership.json`, which
`scripts/check-blorp-layout` enforces). It is a plain transformation from
`FrontendTables` to the `FrontendCompilationGraph` the existing typecheck
reads. It belongs to neither side: the new stage never imports the old
compiler, and typecheck keeps its current input.

**Implemented.** `legacy_declaration_reader(tables, naming)` builds the
indexes the adapter reads by owner, once; then `legacy_parsed_program(reader,
module)` rebuilds one module's `ParsedProgram` (its source file, module
docstring, import blocks, foreign blocks and declarations, in source order, each
with its body) and `legacy_frontend_graph(tables, naming, context)` assembles
the modules, roots, import edges and name table and validates them with the
service the existing discovery uses, so finalization, module surfaces and
validation are the existing code, not a copy.

**Bodies.** `legacy_module_bodies` walks a module's node block once, in table
order. The table is post-order, so a node's children are rebuilt before it is;
each node's value (an expression, a pattern, a match case, a record field, ...,
one variant of the private `BuiltNode` union) is kept at the node's position
and a parent takes its children's by position. Nothing recurses over a body:
the cost of a body nested as deep as the source allows is that of a flat one
(the test builds a 6,000-operand chain). Values are kept by position and not on
a stack because a local function's signature and body roots sit between the
siblings of the statements around it. A parent that finds a child of another
kind, or a count its kind does not document, reports `MalformedNode(node,
kind)`: a `concurrently` loop without a `limit`, which the parser reports,
is one, and the adapter does not invent a limit. A name's span is read from the
name span rows as the walk reaches the node (they are sorted by node), and a
written type child is rebuilt on demand by the declaration half's `legacy_type`.

The adapter hands over interpolated strings in the form the existing front end's
second step produces (`ParsedStringInterpolationPartsExpr`): the existing
parser parses holes after the file, the stage with it, so there is no
unparsed form to rebuild, and the differential compares against the existing
program after `finalize_interpolation_program`. Typecheck's own finalization
(hoisting local functions, rewriting subscript reads) runs on the adapter's
output in `legacy_frontend_graph`, as it does on the existing parser's.

```blorp
---
Rebuilds the existing typecheck's input from the tables. It shrinks as
typecheck is rewritten to read the tables and is deleted when typecheck
takes `FrontendTables` directly.
---
pure func legacy_frontend_graph(
	tables: FrontendTables,
	naming: LegacyModuleNaming,
	context: FrontendGraphContext,
) -> Result[FrontendCompilationGraph, List[FrontendGraphServiceError]]
```

It does no parsing, resolution or checking of its own; anything missing is a
gap in the tables, and the declaration half found and closed these: the name
spans in section 3, the full vocabulary in section 4, the sigil names, and the
end of an import and of an import block. Ids pass through: the name table is
the stage's spellings at the stage's ids; module ids need no mapping because
the order matches the existing graph; definition ids are dropped because the
parsed AST has none. Module names come from the tables: the existing front
end names a module by how it was reached, so an imported module takes its
import request's text (bare, native-package and source-package requests) or
its path without `.brp` (relative requests and user code), an implicit module
its request's name; origins come from the module's origin and package row, and
an embedded standard-library module's path is spelled `<embedded:name>`.
The adapter relies on a stage guarantee: import rows are in load order (module
by module, source order within a module, `ModuleRangesOverlap`), so the first
import row that targets a module is the request that loaded it.
`LegacyModuleNaming` carries the one thing the tables do not hold, the name a
root takes, which the existing front end's callers choose per command: a
function of the root's request path. The body half closed these stage gaps:
the span of a name inside a wider body node (a field, a binding target, a
binder, a pattern's constructor or spread), the span of an `else` keyword, the
form a string pattern was written in, and a parenthesized name keeping its own
span.

A row the tables should hold and do not is a `LegacyAdapterError`
(`MissingTableRow(table, index)`, `NotAWrittenType`, `MalformedNode`,
`BodyRootNotAnExpression`, `ModuleWithoutRequest`, `GraphRejected`) propagated
through `legacy_declaration_reader`, `legacy_parsed_program` and
`legacy_frontend_graph`; no placeholder flows into the AST, and the differential
fails on an error. A read the freeze invariants make total (a node of a module's
block, a child edge in range and before its parent) does not return a `Result`:
a child that is missing or not yet built is `NotYetBuilt`, which no parent takes,
and the parent reports `MalformedNode`.

The first version serves compilation (`check`, `compile`, `run`, `test`); the
formatter, which needs comments the stage drops, and the LSP are decided
after acceptance. The stage loads the implicit modules (section 6), so the
adapter receives every module the existing graph has, in the same order;
nothing in the adapter loads or orders modules.

### Running the stage from the CLI

The CLI reaches the stage through one seam, `frontend_compilation_graph_for_root_paths`
in `blorp/src/lib/source_graph.brp`: every command that builds the graph hands it
the sources it already read (a path, the name the command chose, the text) and
the seam owns parsing (the one exception: a test root that test discovery
already parsed is reused by the existing path, and ignored by the stage). `BLORP_FRONT_END` (`existing`,
the default, or `stage`; anything else is an error) is read once per setup
(each command makes one) and the seam matches on it: `existing` parses the roots and runs the existing
discovery; `stage` runs `compiler/discovery_front_end.brp`, which composes the stage's
inputs from the same setup (the roots' own text as an overlay over the file
system, the standard-library directory or the embedded texts, native package
roots, source packages, the prelude set and for `blorp test` the test runtime),
renders what the stage rejected, and gives the rest to `legacy_frontend_graph`.
A root's placement (standard library, native package, source package, user code)
is the caller's input (`RootRequest`), taken from the existing front end's
origin rule, because it depends on the file system the caller knows.

What a user can see with the stage, beyond the listed help lines above:

- **Stops the stage adds or keeps.** A lexing or parsing error, an import that
  differs from its file only in letter case, an unreadable or oversized source,
  and a missing implicit module stop the front end with the stage's rendered
  diagnostics (`error:`, `path:line:column`, message, `help:`), all of them in
  one report: roots and implicit modules first, then each module's syntax
  errors in module order, then the import problems. An import that resolves to no
  module does not stop it: as today the graph keeps an unresolved edge and each
  command reports it in its own words.
- **Located case mismatch.** An import spelled in another case prints at the
  import (`path:line:column: error: ...`) with the existing message and help; the
  existing front end prints the message alone.
- **Stricter implicit modules.** A standard-library directory without `prelude`,
  `tuple` or (for `blorp test`) `test` is an error (`cannot find implicit
  module`); the existing loader skips a missing one.
- **Library roots.** The configured standard-library directory is made absolute
  and normalized where the setup reads it, and a root inside it is spelled
  absolutely too, so a relative `--std-dir` with a root inside it has one identity
  in both front ends (it used to be a duplicate-identity error).
- **Roots.** A root's path is printed as the caller gave it (`T//x.brp` stays
  so); imported modules print normalized paths, as today. A root already loaded
  as another module's import is one module (by canonical path), where the
  existing front end could hold it twice.
- **Internal errors.** A table invariant violation or an adapter error
  (`LegacyAdapterError`) is reported as `internal compiler error: ...` with the
  table, row and kind: it is a defect of the stage or the adapter, never the
  program's. The one adapter outcome that is the program's, the graph
  validation refusing it (a root named like a standard-library module, two
  modules with one path), prints as the existing front end prints it, without
  that prefix.
- **Names from the working directory.** A module named by its path, a relative
  import or a user module, takes the path from the working directory when the
  file is under it, however the file was reached (`blorp test` names its roots
  absolutely). Later passes key builtin modules on that spelling
  (`blorp_src_lsp_lsp_stdio_transport__...`), so the front end passes the
  convention to the adapter as `LegacyModuleNaming.path_module_name`.
- **Fixtures under the stage.** `run_blorp_check_fixtures.py` checks a
  should_fail fixture against its `EXPECT-DISCOVERY-TEXT` lines and the
  position in its `EXPECT-DISCOVERY` pin when `BLORP_FRONT_END=stage`, and
  against its `EXPECT-BLORP` lines otherwise; the CLI parse-failure checks
  compare the diagnostic lines without the `help:` line.

Superseded: `blorp test` discovery (`test/discovery.brp`) and doctest extraction
(`test/doctest.brp`) still parse with the existing parser as tools, like the
formatter: they need the parsed program of each candidate file to decide which
files are test roots and to generate the doctest roots before any graph exists.

### Proving the adapter

`blorp/test/compiler/tools/discovery_adapter_differential.brp` runs the old
parser and the new discovery plus the adapter over the self-compile root, a
`blorp test` root, each with the standard library on disk and embedded, the
native-package and source-package fixture projects (the module-order check's
options, `module_order_options.brp`), and every tracked `.brp` file (as roots
of one discovery), and compares each module's full parsed AST, bodies and spans
included, through the existing JSON encoder (`parsed_ast_json.brp`), so no
separate renderer is written; the existing side's program is the one its
second step leaves, with the interpolation holes parsed (`with_holes_parsed`,
in `discovery_adapter_comparison.brp`). The encoder gained the `else` keyword's
span, which it did not print. A mismatch names the module, the declaration and
the field. For a root it also builds the existing front end's
graph and compares each module's name, origin and source path, since the
program comparison uses the adapter's own names on both sides. A module the
existing parser rejects is skipped; the parity gate requires the skipped set to
equal the files the existing parser rejects. `scripts/compiler-new-parity` runs it
(`ADAPTER_DIFFERENCES` lists deliberate differences with a reason each; there
are two, for one fixture) and `blorp/test/compiler/stage_04_modules/test_discovery_adapter.brp`
covers one construct group per test, with the corners the differential could
not otherwise be trusted on (brace forms, leading-dot chains after lambdas,
anchored `if` and `match` values, comments between `if` and `else`, minimum
`Int` literals, interpolation escapes and nested strings, docstring
attachment). The tool lives under `blorp/test/compiler` because it imports the
existing compiler, which `compiler_new`'s tests may not. The full comparison
is clean over 3,174 modules and 47,027 declarations in the corpus run, and over
396, 62, 39 and 41 modules in the root runs, with the standard library on disk
and embedded. The same generated C for the self-compile and the test corpus
confirms the rest (roadmap criterion 2); ids are internal identity, so the
adapter passes the stage's name table through instead of imitating the old
numbering, and C that differs only in id-derived names is compared after
normalizing them.

**Where the stage differs from the existing parser.** The language rule is in
`docs/GUIDE.md` and `docs/GRAMMAR.md`: a hole holds any expression, strings
with holes nest to any depth (64 open braces and holes at most), and braces outside a hole are
text. Targeted inputs found four places the existing lexer breaks it:

- a `\u{...}` escape after an interpolated string's first hole stayed as
  written, and a brace or backslash before the first hole was read again by the
  splitter (so `"{kept} ${d}"` made `kept` a hole): fixed in the existing lexer,
  and `test_discovery_adapter.brp` now asserts agreement;
- interpolation nested three levels deep (the existing lexer pairs a nested
  string's quotes with one flag, so the innermost hole becomes text), and braces
  in an interpolated pipe string (every brace is a hole): not fixed, because both
  need the lexer's tail scan rewritten as the stage's frame stack
  (`hole_scan`). Nesting is listed in `ADAPTER_DIFFERENCES` through
  `fixtures/known_differences/interpolation_nesting.brp`; the existing parser
  now rejects the pipe-string braces
  (`fixtures/known_differences/interpolation_pipe_braces.brp`, in
  `KNOWN_DIVERGENCES`). Both are tracked in
  `docs/issues/interpolation_nesting_in_the_existing_lexer.md` and open under
  roadmap criteria 1 and 6.

`# N`, rejected by the new lexer, remains the one intended difference in the
accepted language.

## 11. What changes for later stages

Later stages key everything they learn by these ids, in their own tables:

- typecheck: resolved references, inferred types and selected impls per
  `NodeId`; traits per bound and supertrait row; nothing written back into
  nodes;
- lowering: Core built from nodes, with `DefinitionId` and `NodeId` as the
  identities Core already wants.

Rewriting a part of typecheck to read the tables, and deleting the part of
the adapter that fed it, is the unit of migration. When typecheck reads
nothing the adapter builds, the adapter is deleted, and typecheck's own
output is specified the same way.

## 12. Cost

Discovery of the compiler's own sources (from `blorp/src/main.brp`, 373
modules at the time, before the implicit modules were loaded; with them the
stage loads the existing graph's module count, which cost +1.1% allocations and
+0.3% instructions), each side in its own `-O2` binary, measured
on 2026-09-30 (median of 3; load average 5 to 7):

| | Existing discovery | New discovery | New, without the `freeze` check |
| --- | --- | --- | --- |
| Allocations | 7.91M | 0.435M | 0.380M |
| Instructions | 8.45G | 4.24G | 3.92G |
| Peak RSS | 196 MB | 187 MB | |

The invariant check in `freeze` costs about 8% of the new side's
instructions. While the adapter exists, discovery does more work than
today: it builds the tables and then the legacy output. Acceptance
still requires the stage plus the adapter to cost fewer instructions than the
existing discovery (roadmap criterion 5); the stage's own end-to-end numbers
are measured again when the adapter is deleted.

First adapter measurement (declaration half only, same input, `-O2`, median of
3, 2026-10-01, after the rebase onto the embedded provider; `benchmarks/results/discovery_adapter_declarations_2026-10-01.md`):

| | Existing discovery | Stage, tables | Stage plus adapter |
| --- | --- | --- | --- |
| Allocations | 8.47M | 0.53M | 3.02M |
| Instructions | 10.20G | 4.05G | 5.68G |
| User time | 0.63 s | 0.27 s | 0.38 s |

The declaration half costs 1.62G instructions, 26% of the stage's margin (it
was 1.06G before every row read became a `Result`); the body half is not in
these numbers.

With the body half (same input and method, `-O2`, median of 3, 2026-10-01;
`benchmarks/results/discovery_adapter_bodies_2026-10-01.md`), the stage plus the
whole adapter and the existing finalization costs fewer instructions than the
existing discovery. `programs` is the adapter alone, before typecheck's
finalization of each module:

| | Existing discovery | Stage, tables | Stage plus programs | Stage plus graph |
| --- | --- | --- | --- | --- |
| Allocations | 8.47M | 0.53M | 5.15M | 7.13M |
| Instructions | 10.13G | 4.05G | 7.24G | 8.74G |
| User time | 0.51 s | 0.22 s | 0.39 s | 0.48 s |
| Peak RSS | 198 MB | 189 MB | 206 MB | 373 MB |

The whole adapter (declarations, bodies and the finalization and surface passes
over them) costs 4.69G instructions, 77% of the stage's 6.08G margin: the
stage plus the adapter is 14% under the existing discovery in instructions, 16%
in allocations and 6% in user time, and the margin is no longer wide. The graph
mode holds every module's program at once, as the existing graph does, and its
peak RSS is 1.9 times the existing discovery's. The adapter is deleted as typecheck
reads the tables, so this cost is temporary.

## 13. Deliberately out of scope

- Parallel parsing. Discovery stays sequential; a parallel parse would need
  per-module name tables merged afterwards.
- Incremental re-discovery. Per-module ranges make it possible later; it is
  not part of this design.
- Name resolution and types. Those belong to typecheck's tables.
