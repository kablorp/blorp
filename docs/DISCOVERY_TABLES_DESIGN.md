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
- the module walker and the source providers (file system and in-memory);
- the declaration, type, pattern and body parsers, with accept/reject parity
  against the existing parser over the corpus.

**Pending:**

- **The legacy adapter** (section 10) and its differential check. Nothing
  outside `compiler_new` reads the tables yet.
- **The prelude.** The existing compiler loads 16 prelude modules into every
  compilation; the walker loads only what the roots import. Owner: the
  stage (roadmap C1 and C2); needed before the adapter's differential check
  can pass.
- **The embedded standard-library provider and the package catalog.** Both
  plug into the provider seam (section 5) without walker changes.

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
cannot be mixed up. The constructors are private to `discovery_builder.brp`.

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
opaque type DiagnosticId = Int
opaque type ParameterId = Int
opaque type ForeignBlockId = Int
```

A span is one integer: the source index, then the start offset, then the
length (`span.brp`). There is no `NO_SPAN`: every row that has a span has a
real one, and compiler-synthesized rows point at the syntax that caused
them.

| Field | Bits | Limit |
| --- | --- | --- |
| source index | 15 | 32,768 sources |
| start offset | 24 | 16 MiB per source |
| length | 24 | 16 MiB |

15 + 24 + 24 = 63 bits, so a span is a non-negative `Int`. The walker admits
a source only when its index and byte length fit (`source_admission.brp`);
a source that does not fit is reported with `SourceTooLargeDiagnostic` or
`TooManySourcesDiagnostic` and not parsed, so packing never loses
information.

## 3. Rows

Each table is a list of one struct type (`discovery_builder.brp`); the
payload-free enums the rows store are in `row_kinds.brp`.

### Sources, packages, modules and roots

```blorp
struct RowRange {first: Int, count: Int}

-- The text is `source_texts[source]`; line starts are a block of `line_starts`.
struct SourceRow {path: PathId, line_starts: RowRange}

struct PackageRow {name: NameId, kind: PackageKind}   -- NativePackage | SourcePackage

struct ModuleRow {
	source: SourceId,
	canonical_path: PathId,
	origin: ModuleOriginKind,   -- StdlibModule | PackageModule | UserModule
	reach: ModuleReach,         -- RootModule | ImportedModule
	definitions: RowRange,
	imports: RowRange,
	nodes: RowRange,
	diagnostics: RowRange
}

struct ModulePackageRow {module: ModuleId, package: PackageId}

struct RootRow {request_path: PathId}
struct RootTargetRow {root: RootId, target: ModuleId}
struct RootDiagnosticRow {root: RootId, code: DiscoveryDiagnosticCode, arguments: RowRange}
```

`ModuleReach` replaces the sketch's `is_root: Bool`. Each module's rows in
the definitions, imports, nodes and diagnostics tables are contiguous blocks,
closed when its parse ends. Every root has exactly one outcome: a
`RootTargetRow` or a `RootDiagnosticRow`.

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
	span: Span
}

struct ImportItemRow {owner_import: ImportId, name: NameId, variants: RowRange, span: Span}
struct ImportItemVariantRow {item: ImportItemId, name: NameId, span: Span}
struct ImportBlockRow {module: ModuleId, imports: RowRange, span: Span}

-- Optional relationships: at most one row per owner.
struct ImportTargetRow {owner_import: ImportId, target: ModuleId}
struct ImportAliasRow {owner_import: ImportId, alias_name: NameId}
struct ImportItemAliasRow {item: ImportItemId, alias_name: NameId}
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
`DeclarationHeader` (`declaration_header.brp`), a plain struct, so a header
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

struct TypeParameterRow {owner: DefinitionId, ordinal: Int, name: NameId, kind: TypeParameterKind, span: Span}
-- TypeParameterKind: TypeParameter | DimensionParameter | WildcardDimensionParameter

struct BoundRow {owner: DefinitionId, parameter_ordinal: Int, trait_name: NameId, span: Span}
struct SupertraitRow {trait_definition: DefinitionId, ordinal: Int, name: NameId, span: Span}
struct DimensionConstraintRow {owner: DefinitionId, left: NodeId, right: NodeId, span: Span}
```

A `DefinitionTypeRow`'s role is fixed by the definition's kind: a
function's return type, a global's declared type, an alias's or opaque
type's target, an impl's receiver, a field's type. A bound is a single
trait name (`BoundRow.trait_name`); the sketch's dotted bound paths do not
exist in the language. Typecheck resolves bound and supertrait names.

### Documentation, annotations and foreign declarations

```blorp
struct DocumentationRow {definition: DefinitionId, text: LiteralId}
struct AnnotationRow {definition: DefinitionId, annotation: FunctionAnnotation, span: Span}
-- FunctionAnnotation: TailRecursive | NoCopy | DebugOnly | ResourceResultOrdinary

struct ForeignBlockRow {module: ModuleId, arguments: RowRange, span: Span}
struct ForeignArgumentRow {name: NameId, value: LiteralId, span: Span}   -- `include: "x.h"`, ...
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

**`row_kinds.brp` is the single source for the node kinds.** Its `NodeKind`
docstring gives each kind's payload and child order, and
`node_payload_reference(kind)` says which table the payload indexes:
`NamePayload`, `LiteralPayload`, `CodepointPayload`, `DefinitionPayload` or
`NoPayload` (which stores `NO_NODE_PAYLOAD`). This document does not repeat
the list. There are 123 kinds in these families:

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
  written;
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
recognized by its kind, never by position alone. A compound assignment
(`x += 1`) has only the value child: it has no written type.

**Named arguments.** `f(a = 1)` parses as a `CallNode` whose argument is an
`AssignmentNode` with the parameter's name as its payload. The identifier
leaf parsed before the parser sees `=` is discarded, so no node is
orphaned; the invariants check that every node is referenced exactly once.

**Interpolation.** An interpolated string is an `InterpolatedStringNode` (or
`InterpolatedPipeStringNode`) whose children are, in source order,
`InterpolationTextNode` pieces (payload: the `LiteralId` of the decoded
text) and the hole expressions. A text piece is present before, between and
after holes when it is non-empty. The lexer finds the pieces and hole byte
ranges once, while lexing the string (section 7); the parser never rescans
the string. Text pieces hold decoded text (escapes applied, as in a plain
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
contiguous block; `resolution_diagnostics` holds the walker's (imports that
loaded nothing, sources that could not be admitted). The code catalogue is
`discovery_diagnostic_code.brp`: 100 codes, each documented with the meaning
of its arguments, and `diagnostic_code_name` gives the stable names dumps
and fixtures use. Messages are rendered from the code and arguments at the
boundary that shows them, so the text lives in one place and can be tested
exactly.

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
`discovery_builder.brp`; each site that depends on one cites it by number.
In short: the first update of a builder parameter is unconditional; no tail
call on a reassigned `var`; the builder is not read in another argument of
the call it is handed to; no `f(g(b))`; in loops `out = f(out)`, never
through temporaries; a record update's field value reads only that field;
no aliasing, storing or capturing.

`test_allocation_budget.brp` in the compiler-new gate parses a repeated
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
(`intern_index.brp`): one `List[Int]` of (row, hash) entries, at least twice
as many slots as rows, searchable by a slice of the source text without
allocating the slice. An identifier that is already interned costs no string
at all. The hash is FNV-style mixing finished with MurmurHash3's 64-bit
finalizer; over the self-compile the average probe length is 1.44 for names
and 1.26 for literals. Frozen tables keep the indexes, so readers can look a
spelling up.

Every name table starts with the seeded vocabulary (`name_vocabulary.brp`)
at pinned ids: a copy of the existing compiler's synthesized vocabulary, in
the same order so the adapter's ids agree, followed by the spellings only
discovery compares (`tail_recursive`, `no_copy`, `debug_only`,
`resource_result_ordinary`, `into`). The parser compares annotation names
and the removed conversion by `NameId`, never by spelling.

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
(`source_provider.brp`), so the rest of the phase is pure and an editor can
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
the order they are tried, each with the origin and package the module there
would have; the first that exists wins. The order is language behavior
(native packages only from user modules; relative requests keep the
importer's origin; bare requests from the standard library resolve only in
the standard library). Keeping the policy out of the provider is what makes
an editor resolve exactly like a build.

Implemented providers: `FileSystemSourceProvider` and
`InMemorySourceProvider` (tests and overlays). The embedded standard library
becomes a provider that answers for paths under the standard-library root,
and the package catalog supplies `native_package_roots` and candidate rules;
neither changes the walker.

## 6. The module walker

The walker (`module_walker.brp`) is the phase's only loop over modules:

```blorp
func discover[Provider: SourceProvider](
	provider: Provider,
	lookup: SourceLookupRoots,
	roots: List[String],
) -> FreezeOutcome
```

Roots are loaded in the order given, then every import in the order its
module was loaded and, within a module, in source order (breadth first). A
module is loaded once per canonical path, whichever request reaches it
first, so ids depend only on the roots and the sources. Roots and imports go
through one `load_or_reuse` routine: reuse the loaded module, or admit the
source, lex it, parse its declarations and close its ranges. Each root gets
a target or a root diagnostic (`UnresolvedRootDiagnostic`,
`UnreadableSourceDiagnostic`); each import a target or an
`UnresolvedImportDiagnostic` resolution row. Discovery always goes on.

## 7. Lexing

`lex_source(builder, source)` fills the transient `tokens` table and interns
every identifier, number and string into the builder as it goes. Tokens are
dropped when the next module's lexing starts.

```blorp
struct Token {kind: TokenKind, span: Span, payload: Int}
```

`token.brp` documents each kind's payload. Two differ from the existing
lexer:

- **`DimensionNameToken`.** An identifier written directly after `#` (as in
  `#N`) is one token whose payload is the plain name's `NameId`, so
  adjacency is a lexer fact rather than a parser check on token positions.
  A `#` followed by anything else is a `HashSymbol`. This makes `# N` (with
  a blank) a syntax error; the existing parser accepted it, and nothing in
  the corpus uses it. The adapter mints the old `#N` spelling when it
  rebuilds the existing compiler's identifiers.
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

When the walker is done, the builder is sealed:

```blorp
opaque type FrontendTables = DiscoveryBuilder

union FreezeOutcome:
	FrozenTables(FrontendTables)
	TableInvariantsViolated(List[TableInvariantViolation])

pure func freeze(builder: DiscoveryBuilder) -> FreezeOutcome
```

`freeze` always checks the invariants (`table_invariants.brp`); there is no
trusted mode. The check reads each row a bounded number of times and
reports every violation as a `TableInvariantViolation {kind, table, row,
related_table, value}`, not only the first. `frontend_tables.brp` exposes
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
- `PayloadOutOfRange`: each node's payload is valid for its kind's
  `node_payload_reference` (a scalar value for a codepoint, `NO_NODE_PAYLOAD`
  for `NoPayload`); references are checked by `DanglingReference`.
- `LocalFunctionNodeMismatch`: a `LocalFunctionNode` names a local
  function definition.
- `BodyRootOutsideModule`: a body's root lies in its module's node block.
- `DuplicateSideRow`: at most one import target, import alias, root target,
  module package, definition type or body per owner.
- `RootOutcomeMismatch`: each root has exactly one of a target and a root
  diagnostic.
- `SignatureCountMismatch`: exactly one signature per function-like
  definition and none for others.
- `SideTableUnsorted`: side tables read by owner are strictly sorted by
  owner.
- `SpanOutsideSources`, `SpanPastSourceEnd`: every span names a source and
  ends within its text.
- `SeededNameMoved`: the seeded vocabulary sits at its pinned ids.
- `InternIndexMismatch`, `ParallelTableMismatch`: the intern indexes agree
  with their tables, and parallel tables have equal lengths.

`test_table_invariants.brp` has a negative test per kind and per node
payload class.

## 10. The legacy adapter

Not implemented yet; `docs/DISCOVERY_ACCEPTANCE_ROADMAP.md` orders the work.
The adapter is a plain transformation from `FrontendTables` to the
`FrontendCompilationGraph` the existing typecheck reads. It belongs to
neither side: the new stage never imports the old compiler, and typecheck
keeps its current input. It sits in the compiler's top-level pipeline
(`blorp/src/compiler/pipeline.brp` or a module beside it), the one module the
layout check will allow to import both (roadmap F1).

```blorp
---
Rebuilds the existing typecheck's input from the tables. It shrinks as
typecheck is rewritten to read the tables and is deleted when typecheck
takes `FrontendTables` directly.
---
pure func legacy_frontend_graph(tables: FrontendTables) -> FrontendCompilationGraph
```

It rebuilds each module's parsed program from its definitions and nodes,
spells identifiers from the name table (minting `#N` for dimension names),
renders locations from packed spans and line starts, and derives module
surfaces and import references. It does no parsing, resolution or checking
of its own; anything missing is a gap in the tables. The first version
serves compilation (`check`, `compile`, `run`, `test`); the formatter, which
needs comments the stage drops, and the LSP are decided after acceptance.
Loading the prelude belongs to the stage (see Status), not the adapter.

### Proving the adapter

A differential check runs the old discovery and the new discovery plus the
adapter over every source we have (the compiler, the standard library, and
every test and fixture program) and compares the legacy structures field by
field. A mismatch names the module, the declaration and the field. Once it
is clean on the whole corpus, the new stage becomes the default (roadmap F5)
and the old discovery leaves the compile path later (roadmap G);
byte-identical generated C for the self-compile and the test corpus
confirms the rest. The known intended difference is `# N`, rejected by the
new lexer.

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
modules, without the prelude), each side in its own `-O2` binary, measured
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

## 13. Deliberately out of scope

- Parallel parsing. Discovery stays sequential; a parallel parse would need
  per-module name tables merged afterwards.
- Incremental re-discovery. Per-module ranges make it possible later; it is
  not part of this design.
- Name resolution and types. Those belong to typecheck's tables.
