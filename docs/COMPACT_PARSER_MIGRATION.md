# Compact Parser Migration

Status: design checkpoint. Production implementation requires choosing the
first boundary in [Decision Before Implementation](#decision-before-implementation).

Goal: replace per-expression ownership traffic in the compiler parser with a
validated, product-owned compact representation while preserving the complete
language, diagnostics, recovery, source identity, and downstream semantics.
This is the implementation plan for T7 in the
[Frontend Facts Roadmap](FRONTEND_FACTS_ROADMAP.md#t7-parser-nodes-without-per-node-ownership-traffic).

Read first: [`stage_03_parse/parsed_ast.brp`](../blorp/src/compiler/stage_03_parse/parsed_ast.brp),
[`stage_03_parse/language_parser.brp`](../blorp/src/compiler/stage_03_parse/language_parser.brp),
[`stage_03_parse/source_ast_finalize.brp`](../blorp/src/compiler/stage_03_parse/source_ast_finalize.brp),
[`stage_06_typecheck/headers/global_header_completion.brp`](../blorp/src/compiler/stage_06_typecheck/headers/global_header_completion.brp),
and the measurement protocol in [`benchmarks/README.md`](../benchmarks/README.md).

## Evidence And Scope

The retained experiment at commit `656169d9ba517bccb88cb3ad225670f6fcd9f7e6`
was deliberately narrower than the production parser. On a 21-case expression
corpus, its compact construction-and-consumer path produced the same ordered
identifier-reference output as the recursive-tree baseline. Across its
retained workloads, allocations fell 28.0% to 65.2%, process-wide retired
instructions fell 32.5% to 58.1%, and RSS fell 2.8% to 6.9%. After the compact
product and output were retained through full lifetime, however, retained
bytes were 3,360 versus 2,560 for the baseline, a 31.3% regression. Those
numbers justify investigating the construction boundary; they do not predict
whole-compiler speed or memory and they do not validate the full grammar.

The current production boundary is much broader:

- `ParsedExpr` has approximately fifty variants, including declarations,
  blocks, concurrency, recovery nodes, and interpolation; the broader
  expression graph also reaches separate pattern and binder types.
- `source_ast_finalize.brp` reparses interpolation expressions, hoists nested
  functions, and rewrites subscript reads before typechecking.
- formatter and LSP paths consume raw syntax and recovery information, while
  compile/check/run consume `FinalizedTypecheckProgram`.
- the first measured downstream consumer,
  `parsed_expr_free_identifier_references`, has binding-sensitive rules for
  block order, patterns, `select`, `with`, lambdas, loops, concurrency,
  assignment, and tuple/question bindings.
- global initializer expressions are also needed later by inference. Merely
  attaching a compact sidecar to `ParsedVarDecl` retains both representations
  and does not establish a useful ownership boundary.

The migration must therefore cover one exact production boundary at a time.
No milestone may call a token-subset parser for selected expressions, infer
node kind from spelling or shape, or keep two permanent grammar
implementations.

### Milestone 1 checkpoints

#### Scalar, operator, and call oracle

The first test-only form family covers names, scalar literals, raw parser
interpolation literals, unary/binary/logical operators, calls,
break/continue/void/builtin/missing forms. `ParsedStringInterpolationExpr` is
stored only as the raw parser form in this checkpoint; no finalized
interpolation semantics or rebased-source provenance is claimed. Forms outside
the admitted checkpoints are explicitly rejected by the adapter, so this
product is not a canonical full-grammar parser result.

The retained schema probe keeps its AST inputs outside the measurement epoch.
After the match/pattern checkpoint, the product-only lifetime for sixteen
binary roots (48 nodes) is 8 objects and 4,848 bytes, versus 81 objects and
5,824 bytes for freshly constructed legacy trees with the same root shape.
This is a retained-layout comparison, not a construction-speed claim: the test
oracle pays 233 allocations because it converts an existing AST and runs the
exhaustive validator, while the legacy fixture construction pays 83. Empty,
scalar, and binary compact products retain 2/336, 6/880, and 8/1,040
objects/bytes respectively. Collections/access added five table handles and
64 retained bytes; type/interpolation adds six more handles and another 64
bytes. This cumulative 128-byte fixed increase is explicit rather than hidden
by a large-tree result. The scope-skeleton checkpoint adds three more scalar
table handles and raises ABI `sizeof` from 208 to 232 bytes without leaving the
256-byte allocator class. The match/pattern checkpoint adds five table handles,
raises ABI `sizeof` to 272 bytes, and therefore leaves the runtime's 256-byte
small-object pool. The record is now an ordinary 272-byte heap request.

Both 48-node lifetime fixtures keep the same source and static identifier text
outside the measurement epoch. The compact result additionally retains its
source-owner list, so the comparison does not hide that ownership cost. The
legacy side constructs sixteen fresh three-node trees; the compact side stores
sixteen equivalent roots rather than reusing one compact root.

On the current 64-bit generated-C ABI before collections/access expansion,
source-bearing locations are 16 bytes,
node headers are 48 bytes, bool rows are 1 byte, char rows are 8 bytes,
text/operator/call/unit rows are 8 bytes, and string/interpolation rows are 16
bytes. These rows use inline list storage.
Text values live in one owned string table; text-bearing payload rows store an
index instead of allocating one record per node. The opaque product record is
120 bytes by ABI `sizeof` and occupies a 128-byte allocator size class. With
the five collections/access tables, the product was 160 bytes by ABI `sizeof`
and occupied a 192-byte allocator size class. With the six type/interpolation
tables, it is 208 bytes by ABI `sizeof` and occupies a 256-byte allocator size
class. The nested aggregate probe covers
two roots, 33 nodes, and 31 child ids across record update, dictionary, list,
tuple, vector, field access, and multi-index subscript forms; it retains 12
objects and 5,296 current live bytes. There is no paired legacy claim for that
mixed shape. Raw evidence is reproduced by
`blorp/benchmark/compiler/compact_expression_product_schema_probe.brp`; its
output must be captured with `--leak-check` so live type buckets are available.
The probe label is `current_live_bytes`: the runtime counter is current live
memory at the snapshot, not cumulative bytes allocated during construction.
Generated C confirms inline list storage for the new rows. Field-access
payloads are 24 bytes, record payloads are 16 bytes, record-field rows are 40
bytes, dictionary payloads are 16 bytes, and dictionary-entry rows are 16
bytes on the same 64-bit ABI.

#### Collections and access oracle

The second test-only family covers field access, multi-index subscript, list,
tuple, record, record update, dictionary, and vector expressions. Sequence
item/index counts are derived from the node header instead of duplicated in a
payload row. Record and dictionary payloads own checked slices into separate
inline metadata tables. Record field rows preserve label text, label span, and
field span without managed per-field wrappers; dictionary entry rows preserve
entry spans. Values remain node children in source order.

The direct reference oracle matches the current production consumer: a bare
name target in `qualifier.member` produces one qualified reference, field
labels do not become references, and a non-name field target recursively
visits only its target. Subscript visits target before indices; record update
visits base before field values; dictionaries visit each key before its value.
Tests include chained access, call/subscript targets, repeated labels and
names, grammar-permitted empty aggregate forms, multiple indices, and nested key/value
expressions. There is still no production caller or compact-to-production
bridge.

#### Type-bearing wrappers and finalized interpolation oracle

The third test-only family adds `ParsedAscriptionExpr`, `ParsedRangeExpr`,
`ParsedOpaqueIntoExpr`, `ParsedOpaqueFromExpr`, and
`ParsedStringInterpolationPartsExpr`. It covers both interpolation-part
variants and all eleven current `ParsedTypeExpr` variants. Type nodes, type
children, identifier slices, and identifiers are product-owned scalar rows;
no row retains a managed `ParsedTypeExpr`. Dimension operators, dimension-name
splat status, and function purity are encoded by precise node kinds. Named and
qualified arguments preserve source order, function children are parameters
then result, and array children are element then dimensions.

Finalized interpolation payloads own checked part slices. Literal parts own a
shared-text-table index. Expression parts own a bijective ordinal into the
expression node's child slice, preserving mixed part order without retaining a
managed interpolation-part wrapper. A real parser/finalizer fixture verifies
that hole expressions parsed through the synthetic wrapper project with their
rebased authored offsets, duplicate-hole order, and one authored source owner.
The wrapper source is not retained. Compiler-prelude sentinel locations are
rejected rather than mislabeled as authored source; multi-owner construction
remains a future direct-parser capability and is not claimed by this adapter.

The mixed type/interpolation probe has one root, five expression nodes, four
expression child ids, eight type nodes, seven type child ids, four identifier
slices, five identifiers, and four interpolation parts. It retains 14 objects
and 2,672 current live bytes; there is no paired legacy claim. Generated C
confirms inline storage: type-node rows are 48 bytes, identifier-slice rows are
16 bytes, type-identifier rows are 24 bytes, interpolation-parts payload rows
are 24 bytes, and interpolation-part rows are 16 bytes on the measured ABI.

The round-trip oracle uses nested matches when comparing interpolation parts.
The logically equivalent simultaneous tuple match currently mishandles a later
managed-union payload after a mixed literal/expression sequence. This is a
separate compiler issue, not evidence of lost compact-product data: the added
negative controls reject independently altered nested field names, target
spans, field spans, and enclosing field-access spans. The non-gating standalone
reproduction is
[`compiler_managed_union_tuple_match_repro.brp`](../blorp/benchmark/compiler/compiler_managed_union_tuple_match_repro.brp).
At base `cf43c637e03d49f90bd07f4fc30a275dadae2333`, using `bin/blorp` SHA-256
`1500987a6e6e8f363e3ce9b7b8a33ae00490018ce63a06fc511c6de4d71a4a8b`
and fixture SHA-256
`7184c1ea3ef530131af5f54e28b00e51036cd1ff061d058e191ba6d048fd60ee`, run:

```bash
bin/blorp test --timeout 180 \
  blorp/benchmark/compiler/compiler_managed_union_tuple_match_repro.brp
```

Both cases should pass. Observed behavior is that the nested match passes and
the simultaneous match fails, so this documented reproduction intentionally
returns a failing test status and is not registered in a normal gate.

#### Sequential scope skeleton oracle

The fourth test-only family adds block, immutable and mutable variable
declarations, assignment, all four compound assignments, subscript assignment,
tuple destructuring, and question binding. Three product-owned scalar tables
store control identifiers, identifier slices, and typed binders. A precisely
named `NO_COMPACT_TYPE_ROOT_INDEX` sentinel represents an absent binder type;
the validator rejects every other negative or out-of-range root and requires
each present type root to have one owner.

The direct reference oracle uses scalar enter/leave actions and one local bound
text-index stack. Initializers are visited before their declaration enters the
scope, bindings affect only later block siblings, assignment targets precede
their values, and subscript assignment preserves target/index/value order.
Qualified `name.field` references remain suppressed only while `name` is bound.
No product or builder record is carried by a traversal step, and no node clones
an environment.

At the scope-skeleton checkpoint, generated C confirmed inline storage on the
measured 64-bit ABI: control-identifier rows were 24 bytes,
identifier-slice rows were 16 bytes, and typed-binder rows were 16 bytes. The
complete product record was 232 bytes by ABI `sizeof` and occupied the
256-byte allocator class. The simple-control checkpoint below adds the tuple
binder span to the existing slice row, raising that row to 32 bytes without
adding a table handle or changing the product/allocator sizes.

A deterministic 64-binding scope fixture produces 64 free initializer
references and exactly 2,080 bound-name comparisons, matching the current
modeled `List.contains` work (`64 * 65 / 2`). Its one product contains 193 nodes and 192
child ids and retains 9 objects / 20,656 bytes. This is a scaling control, not
an asymptotic improvement claim: the wide sequential workload retains
quadratic lookup work. An exact-name index should be considered only if later measurement
shows that lookup dominating real source/module workloads.

#### Simple control oracle

The fifth test-only family adds `if` with and without `else`, debug blocks,
`while`, and both name- and tuple-binder `for`. It reuses the existing scalar
node, child, control-identifier, and identifier-slice tables. The generalized
identifier actions now take a child count, so a `for` node shares the same
construction path as the one-child assignment and destructuring nodes rather
than introducing another metadata builder.

Conditions and iterables are visited in the outer scope. A `for` binder enters
only for its body and is removed before later siblings or roots. This remains
true for non-block bodies, nested equal-text shadowing, duplicate tuple names,
and qualified references. Tuple-binder source spans are stored explicitly on
the existing slice row; projection never guesses a span from the first or last
identifier.

The retained simple-control fixture has 13 nodes, 12 child ids, two control
identifiers, one identifier slice, seven free references, and one bound-name
comparison. It retains 9 objects / 2,112 bytes. Before match/pattern tables the
complete product was 232 bytes by ABI `sizeof` in the 256-byte allocator class;
the now span-bearing
identifier-slice row is 32 bytes on the measured 64-bit ABI.
That is an exact 16-byte increase in row storage for each populated identifier
slice before list-capacity and allocator-size-class rounding; it does not
change products whose slice table remains empty.

#### Match and pattern oracle

The sixth test-only family adds `ParsedMatchExpr`, all thirteen
`ParsedPattern` variants, and both named and wildcard list spreads. Five
product-owned tables store pattern nodes, pattern child ids, pattern identifier
slices, pattern identifiers, and match cases. Pattern children and cases retain
source order. A list spread remains metadata on its list-pattern node and is
logically visited after every item, matching the parser rule that a spread ends
the authored list pattern.

Each match case stores its pattern root, case span, and a cached binding count.
The validator recomputes binding counts once in the same postorder pass that
proves pattern graph ownership, and rejects any mismatch before constructing a
validated product. It also rejects backedges, shared or orphan pattern nodes,
aliased or out-of-range identifier slices, foreign source owners, mismatched
payload families, and aliased pattern roots. Traversal may therefore pop the
cached count without risking removal of bindings owned by an outer scope.

The direct reference oracle visits the scrutinee in the outer scope, then each
case independently. Pattern names and named list spreads bind only the matching
case body; constructor and qualifier identifiers do not bind. Item bindings
precede a named spread binding, `or` alternatives preserve their current
flattened source order and duplicates, and no case binding leaks to another
case or a later root. Tests compare ordered production references, exact
round-trip structure and spans, nested equal-text restoration, and real-parser
list spreads both with and without preceding items.

On the measured 64-bit generated-C ABI, pattern-node rows are 48 bytes,
pattern-identifier-slice rows are 32 bytes, pattern-identifier rows are 24
bytes, and match-case rows are 32 bytes. The retained pattern fixture has one
match root, three expression nodes, two expression child ids, thirteen pattern
nodes, twelve pattern child ids, seven identifier slices, seven identifiers,
and one match-case row. It retains 13 objects / 2,864 current live bytes. The
fixture reports one free reference and one bound-name comparison. This is a
layout and semantic checkpoint, not a construction-speed claim. The generated
C and retained probe source SHA-256 values for this checkpoint are
`c2b13db4c9a8f55a6c3b814f05c4e5060e0e16126d1bfbaad45a98f366b74e30`
and `9ae87d5c491049a5083c528c7396ebc1c3c683d28aee22ad38d459130fda860e`.
The captured checkpoint output is
[`compact_expression_product_match_pattern_2026-09-20.md`](../benchmarks/results/compact_expression_product_match_pattern_2026-09-20.md).
The aggregate `compiler-blorp` gate remains intentionally pending until the
final structured-scope checkpoint; C1 uses the owning focused suite and changed
compiler checks.

Remaining milestone-1 coverage is deliberately finite:

1. remaining structured scopes: select, `with`, lambda, and nested function
   declaration, including their pattern/binder metadata;
2. concurrency and recovery: concurrent block/for, detach, their parameter
   metadata, and recovery-sensitive combinations of the existing missing form.

The current declaration has 48 `ParsedExpr` variants. Exactly 41 are now in
the oracle. The remaining 7 are explicit, not an open-ended category:

| Status | Count | Variants |
| --- | ---: | --- |
| Covered | 41 | name; integer, float, string, raw interpolation, bool, and char literals; unary, binary, logical, ascription, range, call, field access, subscript, list, tuple, record, record update, dictionary, vector, opaque into/from, finalized interpolation parts, block, variable declaration, assignment, compound assignment, subscript assignment, tuple destructuring, question binding, if, match, debug block, while, for, break, continue, void, builtin, missing |
| Structured-scope checkpoints | 4 | select, with, lambda, function declaration |
| Concurrency checkpoint | 3 | concurrent block, concurrent for, detach |

After those checkpoints cover every `ParsedExpr` variant and their reachable
pattern/binder rows, milestone 2 starts the first direct canonical construction
path in `language_parser.brp`. It replaces the existing expression-tree
construction for the complete expression grammar in one parser-owned path; it
does not add a form-subset parser or leave the AST adapter in production. The
adapter/projection remain test-only differential oracles, while the first
production change measures direct construction plus the named consuming
projection before any downstream caller migration.

The concrete integration boundary is `ParseExprStep` and the expression
driver rooted at `parse_expression_with_header_span`, `parse_expression`,
`parse_primary_expr`, and `parse_postfix_expr`. Milestone 2 introduces a
phase-specific scalar step carrying only token index, diagnostics, and a
compact expression node id. This is not a record rename: the top-level parse
driver creates and exclusively owns every row buffer and grammar/value/action
stack; helper results transfer only scalar control and ids back to that driver;
publication consumes those buffers into the validated product exactly once.
Existing precedence,
postfix, block, and recovery helpers append completed scalar rows through that
driver instead of returning `ParsedExpr`. Type parsing publishes type-root ids
into the same product. Declaration/program assembly then publishes one
validated product; the test-only AST adapter is never called by this path. A
named consuming projection at the finalized-program compatibility boundary is
measured and retained only until its enumerated downstream callers migrate.

## Goals

- One grammar and recovery implementation constructs the canonical expression
  product for every expression form it claims to own.
- Node and row identities are dense, product-scoped ids. Public APIs keep ids
  attached to one traversal; any necessary detached-id boundary explicitly
  checks provenance.
- Construction uses one private mutable builder; publication yields immutable
  validated facts.
- Consumers traverse tables by id without rebuilding a recursive tree or
  scanning the product to rediscover invariants.
- Source spelling, exact spans, diagnostic order, recovery facts, binding
  order, duplicate references, and generated output remain identical.
- A projection exists only at a named compatibility boundary, is consumed
  rather than cached beside the compact representation, and has a deletion
  milestone.
- Performance claims use direct same-boundary measurements and whole-compiler
  confirmation. Negative results are valid.

## Non-Goals

- No source-language, diagnostic, recovery, formatter, LSP, type-system, Core,
  runtime, or generated-C behavior change.
- No reduced grammar, best-effort parse, name-based heuristic, unsafe indexing,
  unchecked cast, or validation deferred to every consumer.
- No benchmark-only production API or data layout chosen only for the current
  free-identifier consumer.
- No eager `ParsedExpr` tree plus compact mirror in a long-lived program or
  module record.
- No permanent general parser plus compact special-case parser.
- T7b cursor changes, name interning, and unrelated frontend-table migrations
  remain separate work.

## Canonical Product Schema

The public representation should be an opaque `ValidatedExpressionProduct`.
Only its owning module can construct or unwrap its representation. Integer ids
are dense offsets, not generatively branded capabilities: two products can
issue the same integer. The initial API therefore exposes no detached ids.
Callers pass a borrowed product to a traversal and receive independently owned
facts; traversal control remains inline integer state rather than an allocated
cursor carrying the managed product. If a later boundary truly needs detached
ids, that change must introduce and measure an explicit owner key. A structural
hash or global mutable counter is not collision-proof identity. The module does
not expose parallel lists that callers can combine incorrectly.

The initial schema should use these concepts; exact Blorp record names can be
settled in the schema commit:

```text
ValidatedExpressionProduct (opaque)
  source_owners: List[ExpressionSourceOwner]
  nodes: List[ExpressionNodeHeader]
  child_ids: List[ExpressionNodeId]
  identifier_rows: List[IdentifierRow]
  literal_rows: List[LiteralRow]
  call_rows, field_rows, block_rows, if_rows, match_rows, ...
  pattern_rows and pattern_child_ids
  binding_rows
  recovery_rows
  diagnostic_rows
  roots: List[ExpressionNodeId]

ExpressionNodeHeader
  kind: ExpressionNodeKind
  payload_row: Int
  span: ProductSourceLocation
```

`ExpressionNodeId`, `PatternNodeId`, and any row id are opaque integer ids.
They are meaningful only during a traversal of their owning product, but an
ordinary range check cannot distinguish a same-range id from another product.
The initial API prevents routine misuse by hiding detached ids. A future
detached-id boundary must validate provenance as well as range.

`ProductSourceLocation` pairs an owner-table id with `SourceLocation`. Each
`ExpressionSourceOwner` says whether the text is an authored file, an authored
range reparsed during interpolation, or compiler-synthesized text with an
explicit diagnostic origin. Interpolation rebasing, nested-function hoisting,
and other finalization work must preserve or deliberately create this
provenance. The product retains every source/token text owner needed by its
rows; releasing lexer tokens cannot invalidate later text or locations.

`ExpressionNodeKind` is a precise enum. Each kind indexes exactly one
kind-specific payload table, such as a binary row, call row, block row, match
row, or binding row. This avoids both a boxed union per node and a broad record
whose nullable fields permit invalid combinations. Variable-length children
use a `(start, length)` slice into an append-only id table. Child order is
source order unless the grammar explicitly defines another order.

Text ownership is explicit:

- authored identifiers and literals retain either the exact immutable text or
  an exact byte range into the product's source; the schema must not normalize
  spelling needed by formatter or diagnostics;
- synthesized text created by finalization belongs to the product's immutable
  text table and survives after the private builder is released;
- consumer outputs own their strings when their lifetime can exceed the
  product. A returned reference must never borrow builder storage.

Families with distinct invariants receive distinct rows rather than flag
combinations. At minimum this applies to match patterns and binders, select arm
kinds, `with` bindings and error maps, concurrent forms and parameters, record
fields and updates, dictionary entries, interpolation parts, lambda/for/param
binders, and assignment forms.

The enclosing canonical parse result is a phase-specific compact program, not
`ParsedProgram` plus a sidecar:

```text
CompactParsedProgram
  source_owners
  declarations: List[CompactParsedDecl]
  expressions: ValidatedExpressionProduct
  diagnostics and ordered recovery events

CompactParsedDecl
  declaration metadata
  expression roots for initializer/body/default expressions
```

`CompactParsedDecl` mirrors every declaration family but replaces each
embedded `ParsedExpr` with an internal expression-root reference. Nested
function declaration expressions use the same compact declaration rows rather
than embedding `ParsedFunctionDecl`. `ParsedTypeExpr` may remain a separately
owned raw type tree in the first slice because it does not contain
`ParsedExpr`; its exact ownership is a field of the compact program, not a
pointer back into a legacy `ParsedProgram`. Match cases own compact pattern
roots and expression roots. Declaration-to-root, diagnostic, and recovery
event order is explicit in this envelope.

## Construction And Validation

"Private builder" means buffers local to one pure driver, not a builder record
returned through every recursive grammar call and not a new mutable-reference
capability. The production construction API is:

```text
parse_expression_product(tokens, source_owners, start_cursor)
  -> ParseExpressionProductStep
```

That function owns local `var` row buffers plus explicit grammar and value
stacks. One iterative dispatch loop consumes tokens, appends complete rows, and
returns a validated product and next cursor. Small private helpers may classify
a token or construct one row value, but they do not accept and return the row
buffers. Nested expression contexts push frames into the same driver. This
control model must be demonstrated for each form-family checkpoint before the
production parser switches; it cannot fall back to threading a growing product
record through approximately fifty existing grammar functions.

Milestone 1 uses the same ownership technique in a test-only AST adapter:
`compact_expression_oracle_from_parsed(source_owners, root)` has one set of
driver-local buffers and an explicit visit/rebuild stack. Its inverse,
`compact_expression_oracle_project(product)`, is test-only. Neither API is
called by production code.

The driver does not publish partially initialized nodes. Its finish path runs
the full validator and either publishes `ValidatedExpressionProduct` or
returns an explicit construction error. Production callers never receive raw
buffers or partially validated state.

Validation establishes at least:

- every root, child, payload, pattern, binding, recovery, and diagnostic id is
  in range and belongs to the same product;
- every node kind selects the correct payload table and each payload row is
  owned by exactly one node unless the schema explicitly permits sharing;
- every child slice is in range, ordered, and belongs to the declared family;
- authored spans are ordered byte offsets within the owned source; synthesized
  spans use an explicit source rule rather than a magic value;
- grammar-required arity and optionality are represented by the row type, not
  rechecked by consumers;
- recovery nodes preserve the parser's missing-token facts, discarded-token
  order, diagnostic order, and resume location;
- references to exact token text or source ranges remain valid for the full
  product lifetime.
- child ids are postorder predecessors of their parent, so the graph is
  acyclic; every non-root node has exactly one parent unless a future row type
  explicitly introduces sharing;
- every node is reachable from exactly one declared root, child slices do not
  overlap, and payload rows are neither orphaned nor multiply owned;
- recovery and diagnostic rows carry a monotonically increasing event index,
  are associated with a program, declaration, or expression root, and
  reproduce the parser's global encounter order.

These checks run once at the construction boundary, not once per consumer. The
first production implementation runs the exhaustive validator in every build.
A later change may replace a particular scan with a smart-construction proof
only when the API makes the invalid state structurally impossible, differential
tests exercise that proof, and measurements justify the change. A comment or a
debug-only assertion is not sufficient evidence for eliding release
validation.

## Semantic Compatibility Contract

The full grammar and recovery surface must be inventoried from parser tests,
not reconstructed from the experiment. Differential tests must include every
`ParsedExpr`, pattern, binder, select arm, with-binding, concurrent, record,
dictionary, interpolation, and missing-expression form.

For identifier references, compatibility means the exact ordered list,
including duplicates and spans. It also includes the existing special rules:

- field access qualifies names without converting the field token into a free
  identifier;
- block bindings become visible only after their initializer and preserve
  sequential scope;
- match-case pattern names are bound only in the corresponding body;
- receive, `with`, lambda, `for`, and concurrent binders have their current
  scopes;
- assignments, tuple destructuring, and question bindings keep their present
  read/bind behavior;
- nested function declaration expressions contribute no direct references at
  the current consumer boundary.

Finalization is part of the contract. Interpolation reparsing, nested-function
hoisting, and subscript-read rewriting must either operate directly on the
compact product or occur before a one-way compact handoff. A consumer cannot
run on a pre-finalized compact view and claim equivalence to the current
post-finalization AST.

Raw parser consumers remain explicit. Formatter and LSP migration is a later
milestone unless the chosen first boundary includes their exact recovery and
token requirements. They may temporarily use a consuming projection, but a
second parser is not permitted.

## Ownership And Lifetime

The desired lifetime is linear by phase:

```text
private builder -> validated compact product -> direct consumers
                                         \-> consuming projection -> next phase
```

A phase record owns one canonical expression representation. If a compatibility
projection is required, the function consumes the compact product and returns
the legacy representation; it does not add a cached AST field beside compact
tables. Likewise, output from the free-identifier consumer is independently
owned and remains valid after releasing the product.

The current `FinalizedTypecheckProgram` is only an opaque `ParsedProgram`, and
stage 04 and stage 06 repeatedly unwrap it. A production cutover must replace
that alias with a phase-specific representation or introduce an even narrower
phase-owned initializer product. Adding a compact sidecar to the current alias
is explicitly rejected.

The first production lifetime is ordered as follows:

```text
compact program
  -> compact-aware finalization
  -> module surface plus independently owned initializer-reference facts
  -> consuming projection to the legacy finalized program
  -> stage 04/06 use the legacy program and retained facts; compact is gone
```

`GlobalInitializerReferenceFacts` retains its own source-owner table once per
module and ordered reference rows containing owner-table ids and locations.
It therefore survives compact-product release without detaching a bare
`SourceLocation`. Later graph completion resolves these facts to global rows;
it does not need the compact product. Finalization should normalize ordinary
authored and interpolation-rebased spans to the module's primary source owner,
while representing any genuine synthesized origin explicitly.

Current consumer groups that the migration must account for are:

- raw syntax and recovery: formatter projection, LSP diagnostics/analysis,
  parsed AST JSON/debug output, test discovery, and doctest;
- finalization: interpolation reparsing, nested-function hoisting, subscript
  rewriting, and import-path rewriting;
- finalized metadata: pipeline/module-surface construction, loaded-module and
  frontend-graph services, source-name/definition indexing, and frontend
  summaries;
- typed frontend: bridge and frontend-graph typecheck, declaration/header
  installation, global-header completion, inference/type occurrence, and
  stage-07 global materialization.

Milestones 2 through 4 move the parser, finalization, module-surface reader, and
initializer-reference publication. All other finalized consumers use the one
consuming projection until their named milestone moves. Raw consumers continue
through a raw compatibility result from the same parser, never a second grammar
implementation.

## Staged Milestones

Each milestone is independently reviewed, tested, and measured. A milestone
that fails its semantic or cost gate is reverted or redesigned rather than
papered over with another retained representation.

1. **Schema and oracle.** Add the opaque product, driver-local builder buffers,
   validator, fixture inventory, and test-only AST adapter/projection used as a
   differential oracle. Land reviewable form-family checkpoints (scalar and
   operator forms; collections/access; control flow and bindings; patterns;
   concurrency and recovery), each with round-trip and corruption fixtures.
   No production caller changes. The product is not considered full-grammar
   until every family is covered.
2. **One canonical construction boundary.** Teach the production expression
   parser to construct the compact product for the complete expression grammar
   and recovery surface. Keep declarations/types raw only where the boundary
   says so. Any legacy expression projection is consuming and instrumented.
3. **Finalization.** Move interpolation, nested-function, and subscript-read
   finalization to compact tables, preserving diagnostics and spans exactly.
4. **First direct consumer and projection boundary.** Publish module surfaces
   and independently owned ordered global-initializer reference facts directly
   from compact data, then consume/project the compact program for remaining
   finalized-AST callers. Global-header completion resolves the published
   facts instead of walking `ParsedExpr`. Output must match exactly for the
   full compiler corpus, including order and duplicates before dependency
   deduplication.
5. **Typecheck projection removal.** Migrate inference and declaration
   consumers family by family until no `ParsedExpr` projection remains in the
   compile/check/run pipeline; remove the compatibility projection in the same
   milestone as its last caller.
6. **Raw-tooling consumers.** Migrate formatter, LSP, JSON/debug output,
   doctest, and test-discovery paths according to their token and recovery
   needs. Delete legacy expression construction once the last caller moves.
7. **Cursor follow-up.** Consider T7b only after compact nodes are canonical
   and separately measured.

Milestones 2 through 5 may need more than one commit, but no commit may leave a
new permanent parser or an undocumented dual-representation lifetime.

## Tests And Measurements

Fast feedback:

- parser and finalizer fixtures for the exact form being changed;
- `blorp/test/compiler/stage_03_parse/test_parser.brp`;
- `blorp/test/compiler/stage_03_parse/test_source_ast_finalize.brp`;
- `blorp/test/compiler/pipeline/test_global_header_completion.brp` for the
  first direct consumer;
- validation tests that deliberately construct every rejected id, row, slice,
  span, and family mismatch through test-only builder hooks.

Every construction milestone also runs all parser-owned manifest checks and
`scripts/compiler-check --changed`. Before direct `bin/blorp` tests, verify
`scripts/compiler-build-status`; rebuild with `make` when it is not `FRESH`.
Broader compiler and sanitizer gates follow the owning test suites.

Differential evidence must cover:

- all expression grammar and error-recovery fixtures, not a token subset;
- exact diagnostics including order, message, help, and span;
- exact raw syntax projection where formatter/LSP depend on it;
- exact finalized AST or typed/Core output at transitional boundaries;
- exact identifier-reference order, duplicates, qualification, and spans;
- identical generated C for the small program and self-compile corpus.

Cost evidence is collected at the boundary changed. Report at least parser and
consumer allocations, retired instructions, peak and retained memory, output
identity, source/binary provenance, raw artifact paths, and release order. Run
the repository self-compile protocol for whole-compiler confirmation. A win in
construction paired with higher full-lifetime retention is not accepted
without showing the product is consumed before the peak.

Schema checkpoints additionally measure empty and small products. Report the
size and retained allocation shape for an empty root set, one scalar, one
binary expression, and a small module's root set. Count every allocated table,
including empty lists, and report node-header and family-row widths. A schema
that saves large-tree traffic but adds substantial per-module table overhead
must change before production construction.

## Compatibility Projection Exit Criteria

A production projection must have all of the following before it lands:

- an enumerated caller list and owning milestone;
- evidence that compact and projected trees are not retained together across a
  phase boundary;
- a counter or profile row measuring projection calls, allocations, and time;
- differential tests for every projected form;
- a deletion condition: the last listed caller moves, then the projection and
  its tests are deleted in the same milestone.

Projection cost is charged to the candidate in benchmarks. It cannot be
excluded as setup if production pays it.

## Decision Before Implementation

The repository survey found no honest tiny direct-parser cutover. Choose one of
these boundaries before production code begins:

### A. Canonical Full-Expression Construction (recommended)

Complete milestone 1, then implement milestones 2 through 4 as the first
production slice: the full expression grammar constructs the validated
product, compact-aware finalization preserves current semantics, and
module-surface and global-initializer reference-fact publication are the first
direct consumers. The compact program is then consumed into a compatibility
projection for remaining typecheck callers; later dependency resolution reads
the independently owned facts. Require a review checkpoint after each form
family; do not switch production construction until the complete owned grammar
is coherent.

This is larger than the experiment, but it establishes the intended ownership
model, keeps one grammar, and measures the real construction/consumer path.
The work should be split into reviewable schema/oracle, construction,
finalization, and consumer commits; production wiring lands only when the
whole slice is coherent.

### B. AST-To-Compact Test Oracle (not a production option)

Convert parsed AST fixtures to a validated compact product, project them back,
and compare the real consumer outputs in tests. This proves schema and consumer
semantics in form-family checkpoints, but it pays for both constructions and
is not a parser migration or a speed claim. It must not be wired into the
production compile/check/run pipeline.

The adapter is deleted after option A's canonical parser construction and the
last differential caller move. Do not implement A and B as competing
production paths. A is the chosen migration direction; B exists only as its
temporary test oracle.
