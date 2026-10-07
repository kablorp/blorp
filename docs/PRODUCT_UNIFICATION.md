# Product Unification

Status: plan; slice 1 (one projection form) is implemented, the rest is not.
Records and tuples become one
product family in Core, the ownership passes, the runtime and the C backend,
so each optimization written for one applies to the other and the parallel
code for the two is deleted. Typecheck keeps them apart: a record is nominal,
a tuple is structural, and their trait implementations differ.

Read [`WORKER_CHECKLIST.md`](WORKER_CHECKLIST.md) before implementing or
measuring a slice. This plan assumes the inline fixed-record change on branch
`records/inline-fixed-records` lands first (section 1.4). It owns the Core
product model, scalar replacement and multi-values. Increments 3, 4, 5 and 7 of
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md)
stay there, restated for products. Declaration/use identity stays in
[`FIXED_LAYOUT_ROADMAP.md`](FIXED_LAYOUT_ROADMAP.md) and
[`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md). `Option`, `Result` and other
unions stay tagged sums and are out of scope.

## Why

Core has two product families, and each optimization exists for only one of
them:

| | Records | Tuples |
| --- | --- | --- |
| Core type | `HeapRecordType(String)` (and `NamedType` before layout resolution) | `TupleType(List[CoreType])` |
| Build | `RecordExpr`, then `RecordConstructExpr` after `prepare` | `TupleExpr`, then `TupleConstructExpr` with per-slot classes and retain/release masks |
| Read | `ProductFieldExpr(base, ordinal)` (slice 1) | `ProductFieldExpr(base, ordinal)` (slice 1) |
| Update | `RecordUpdateExpr`, `RecordReuseExpr`, `RecordCowUpdateExpr` | none |
| Optimizations | in-place reuse, copy-on-write, update threading, consuming clones | scalar replacement of locals and match subjects; multi-values on the increment 2 branch |
| Runtime box | one typed C struct per record, with `_make`, destroy and reuse helpers | generic `blorp_Tuple` with a varargs constructor, a release mask and a separate box for each inline-struct element |

Counted in `stage_08_core_lower`, `stage_09_core` and `stage_10_backend`: the
three tuple expression forms have 185 match arms (748 lines), the five record
forms and `FieldExpr` have 380 arms (1,975 lines), and `HeapRecordType` and
`TupleType` have 178 arms (820 lines). Most pairs repeat each other. The
tuple-only modules `tuple_flatten.brp`, `tuple_element_producers.brp` and
`prepared_tuple_renderer.brp` hold 2,880 lines, and functions named for tuples
elsewhere in those stages hold another 2,032.

The prize is measured. The source-level `Cursor` reconstruction kept three
coordinates scalar and cut self-compile allocations by 13.93% and retired
instructions by 8.19%
([report](../benchmarks/results/cursor_scalar_reconstruction_2026-10-04.md)).
The [record allocation census](../benchmarks/results/record_allocation_census_2026-10-04.md)
ranks small records next: `OwnershipUseSummary` (4 fields, 5.3 M
allocations), `PerceusOwnershipSummaryFrame` (5 fields, 5.2 M),
`CoreMapState` (2 fields, 3.3 M and 2.0 M for two instances) and others with
2 to 5 fields. Increment 2, paused on branch `core/multi-value-results`, cut
self-compile tuple allocations by 46.6% with total allocations flat and
retired instructions +0.68%, within run-to-run noise (its measurement report
is on that branch).

The same loop shows the gap. `cursor_at` advances a three-field `record
Cursor`; `cursor_at_tuple` is the same code over `(Int, Int, Int)`. Measured
with `bin/blorp run --no-format --memory-stats` over 100,001 iterations:

| Compiler | Record loop allocations | Tuple loop allocations |
| --- | ---: | ---: |
| `main` | 100,002 | 100,002 |
| increment 2 branch | 100,002 | 0 |

Section 3.1 shows the Core of both.

## Design summary

| Question | Design |
| --- | --- |
| Where the family distinction lives | Typecheck owns it fully. In Core it is only the identity inside an opaque `CoreProduct`; no optimization branches on it. |
| Core type | `ProductType(CoreProduct)` replaces `HeapRecordType` and `TupleType` once representation is decided after mono; before that, records are `NamedType` and tuples `SourceTupleType`. A separate `MultiValueType` holds elements travelling as values. |
| Field identity | `CoreFieldOrdinal`, issued by the product's layout. The typecheck `FieldId` stays a column of the record row only. |
| Representation | `ManagedBox` or `InlineValue`, carried in the product type and separate from identity. Inline fixed records supply the first `InlineValue` products. |
| Operations | One build, read, update, reuse and copy-on-write form for both families. Evaluation order and storage position are separate facts. |
| Equality and hash | Tuples and records resolve to trait implementations, a record's derived fieldwise when none is written. Core has no native equality for products. |
| First optimization | Scalar replacement of managed products within and across calls, records admitted. It is increments 1 and 2 generalised. |
| Runtime | Tuple boxes use the record emitter's typed layouts. The runtime's own tuple producers move behind a defined boundary. |

## 1. Data model

### 1.1 Where the distinction lives

Typecheck keeps `SemanticTupleType` and nominal record types apart. Structural
typing, field-name diagnostics, the 2-to-4 element rule, and the trait
implementations in `standard_library/src/tuple.brp` all depend on the family.
Typecheck changes only through the declaration/use identity work.

After mono, the representation pass maps both to `ProductType` (section 1.2).
From then on the family is consulted in exactly these places:

- type equality: a record product equals another only by record identity; a
  tuple product equals another by element types; a record never equals a tuple;
- C type naming and the layout key;
- boundary policies: a declared native ABI record's adapters, and the runtime's
  own tuple producers until the runtime slice;
- dumps and diagnostics, which print record field names.

Construction, projection, update, reuse, ownership, scalar replacement and
multi-values never ask. `CoreProduct` is opaque to make that a type error
rather than a review rule. This follows Rust's MIR, where tuples, structs and
closures share one aggregate kind. OCaml's lambda form goes further and erases
records into blocks; Blorp keeps the identity because equality, naming and
ABI boundaries need it.

### 1.2 Core types

Today, `blorp/src/compiler/stage_09_core/ir.brp:1269`:

```
union CoreType:
	VoidType
	NamedType(String, List[CoreType])
	TypeParameterType(String)
	SelfType
	FunctionType(Bool, List[CoreType], CoreType)
	StackResultType(CoreType, CoreType)
	BoxedResultType(CoreType, CoreType)
	EnumType(String)
	HeapRecordType(String)
	UnionType(String)
	RangeType
	TensorType(CoreTensorTypeInfo)
	TupleType(List[CoreType])
```

`HeapRecordType(String)` keys a record by its rendered instance name. Module
prefixes keep two user modules apart (`alpha__Point` and `beta__Point` in a
probe), but the key is still a spelling, and a local `union Option[T]` beside
the prelude `Option` lowers to one Core type reference, a case where rendering
does not separate two declarations. `TupleType` is also spelled
`NamedType("Tuple", args)` in places (`lower.brp:2453`,
`type_policy.brp:329`). On the increment 2 branch, `TupleType` means a source
tuple before `tuple_flatten` and a multi-value after it, with
`BoxedTupleType` for boxes. One variant with two phase-dependent meanings
needs a whole-program ingress check to keep the meanings apart.

After:

```
union CoreType:
	VoidType
	NamedType(String, List[CoreType])
	TypeParameterType(String)
	SelfType
	FunctionType(Bool, List[CoreType], CoreType)
	StackResultType(CoreType, CoreType)
	BoxedResultType(CoreType, CoreType)
	EnumType(String)
	UnionType(String)
	RangeType
	TensorType(CoreTensorTypeInfo)
	-- A record or tuple value. Its representation (a managed box or an inline
	-- value) is part of the product, so any pass reads it from the type.
	ProductType(CoreProduct)
	-- The elements of a managed product travelling as separate values: the
	-- result of a function, or the value an `UnpackLetExpr` binds. Never the
	-- type of a binder or parameter, never nested in another type. Only scalar
	-- replacement creates one.
	MultiValueType(List[CoreType])


--- What a product is. A record product is one record instance and takes its
--- fields from that instance's row. A tuple product is structural, and its
--- element types are its identity. Each carries its representation, set only
--- by the two constructors, which only the representation pass calls (see
--- below). No other passes construct or match the representation: they use
--- the accessors below, so none can branch on the family.
private union CoreProductRep:
	RecordProduct(CoreRecordRef, CoreProductRepresentation)
	TupleProduct(List[CoreType], CoreProductRepresentation)

opaque type CoreProduct = CoreProductRep

-- The whole public surface (signatures only):
--   record_product(rows: CoreRecordRows, record: CoreRecordRef) -> CoreProduct
--   tuple_product(elements: List[CoreType]) -> CoreProduct
--   product_representation(product: CoreProduct) -> CoreProductRepresentation
--   products_equal(left: CoreProduct, right: CoreProduct) -> Bool
--   product_layout(view: CoreProductLayoutView, product: CoreProduct) -> CoreProductLayout
--   product_c_type_key(view: CoreProductLayoutView, product: CoreProduct) -> CProductTypeKey
--   product_display(names: CoreNameView, product: CoreProduct) -> String
```

A structural product has no field names to carry, because a tuple product has
only element types and every read names an ordinal. A nominal product has no
structural comparison, because `products_equal` compares record refs for
record products.

A `ProductType` always has a decided representation; there is no undecided
value. Products exist earlier: lowering builds tuple types for generic
templates (`lower.brp:1364`), and representation can only be decided once
mono has made every instance concrete. Before that point a record is a
`NamedType`, as it is today until layout resolution, and a tuple is
`SourceTupleType(List[CoreType])`, today's `TupleType` renamed to say what it
is. The representation pass, which the inline change adds as
`record_representation` right after mono, is the only producer of
`ProductType`: it rewrites every record `NamedType` and every
`SourceTupleType` in one walk. Its invariant rejects a `SourceTupleType`, or a
`NamedType` naming a record, in its output, so no later pass sees a
pre-decision product.

### 1.3 Identity: record refs and field ordinals

```
--- A record instance row: the declaration's checked identity and, for a
--- generic record, the instance mono created. Issued when the row is
--- accepted, so a lookup of an issued ref cannot miss. Valid within one
--- compilation; never stored across compilations or compared with a ref from
--- another program.
opaque type CoreRecordRef = Int


--- A field's position in its product: declaration order for a record,
--- element index for a tuple. Valid only with the product type of the
--- expression it reads, and in range for it by construction: lowering
--- issues it from the record row or tuple arity it checked.
opaque type CoreFieldOrdinal = Int
```

The record ref depends on declaration/use identity, item 1 of
[`FIXED_LAYOUT_ROADMAP.md`](FIXED_LAYOUT_ROADMAP.md#recover-ownership-prerequisites-in-bounded-slices).
The unlanded identity candidate carries a checked `TypeId` from typecheck
into Core as `CoreRecordSourceIdentity`, which has `IssuedRecordSource(TypeId)`,
`UnvalidatedRecordSource(Int)` and `StandaloneRecordSource` cases. The record
ref is issued only for a row whose identity is `IssuedRecordSource`. The
decoded and standalone states stay legal for JSON and test fixtures but can
never become a `ProductType`. Following
[`IDENTITY_ROADMAP.md`](IDENTITY_ROADMAP.md#type-identity-and-interning), the
declaration's `TypeId` alone does not identify a generic instance: the ref
names the instance row, which holds both. No second definition table is
built; the ref indexes the existing record declaration rows through a
read-only view.

Since slice 1 a field read (`ProductFieldExpr`) carries only the ordinal.
Lowering issues it from the accepted record row of the selection's `FieldId`
(`record_field_ordinal` in `lower.brp`) or from the checked tuple arity, and
returns an internal error for a record selection without a `FieldId`; the JSON
decoder rejects a product read without an ordinal. The emitter spells the
member `f<ordinal>`, or the row's source name for a declared native ABI record
(`c_record_member_at`). Record construction still carries `CoreFieldRef`s
until slice 2.

`Range` is `fixed record Range {start: Int, end: Int}`
(`standard_library/src/range.brp`), an inline record read with
`ProductFieldExpr` like any other; it needs no form of its own.
`CoreType.RangeType` is a different type: the `..#N` refinement index, a C
`long`. It is not a product and stays.

### 1.4 Representation is separate from identity

The inline fixed-record change makes a `fixed record` whose fields are all
numbers, `Char` values or other eligible fixed records a C struct by value
with no ARC header. `Bool` waits for fixed unions. That is the first product whose representation is not a managed box.
Representation and identity are independent axes:

| | Managed box | Inline value |
| --- | --- | --- |
| Record product | every non-eligible record | an eligible `fixed record` |
| Tuple product | every tuple today | a tuple whose elements all pass the same eligibility test (runtime slice onward, if decision 6 is adopted) |

```
--- How a product is stored. Decided once, after mono, by the representation
--- pass: for a record from its row (the pass is the only constructor of an
--- inline record row), for a tuple from its concrete element types. Never
--- decided earlier, so it has no undecided state.
enum CoreProductRepresentation:
	ManagedBox
	InlineValue


--- How one field is stored inside a product. Derived from the field type by
--- one function, so a layout and its field types cannot disagree.
union CoreFieldStorage:
	-- An integer, `Char`, enum or `Bool`, stored as its C scalar.
	ScalarField
	-- A `Float`, `Float32` or `Float16`, stored as its C float type.
	FloatField(CoreFloatWidth)
	-- An ARC pointer the product owns and releases.
	ManagedPointerField
	-- A pointer the product does not own (`Ptr`, a raw foreign handle).
	UnmanagedPointerField
	-- A by-value C aggregate: an inline record or a stack `Option`/`Result`.
	-- Its release policy says whether it owns managed children.
	InlineAggregateField(CoreReleasePolicy)
	-- A `Void` element: no storage.
	VoidField


enum CoreFloatWidth:
	Float64Width
	Float32Width
	Float16Width


record CoreProductFieldLayout {
	typ: CoreType,
	storage: CoreFieldStorage
}


record CoreProductLayout {
	representation: CoreProductRepresentation,
	fields: List[CoreProductFieldLayout]
}
```

The inline change's `InlineRecordType(String)` and `InlineRecordDecl` fold
into `ProductType` with `InlineValue` in the product-type slice. Eligibility is
one function of field types. A scalar-only tuple is the same plain-data case
as an eligible fixed record and uses the same test. The difference is the
promise: `fixed` lets typecheck reject a record that fails the test, while a
tuple has no declaration that can promise anything.

An inline product is already a value, so scalar replacement and multi-values
apply only to `ManagedBox` products; C's optimizer splits a by-value struct
itself. Ranges are inline and never flattened. `Cursor` is a `fixed record`
of three `Int`s, so the inline change alone removes its allocations; slice 3
proves its target on a managed record of the same shape. Multi-value
transport structs and inline tuples share one layout registry keyed by
element types (decision 10).

### 1.5 The layout view

Representation needs no view: it is part of the type (section 1.4), so
`is_managed_type` and every early pass, including scalar replacement in the
early pipeline, read it from the type alone. Record field types come from the
record rows already in the program; scalar replacement builds a read-only
field-type index from them once per run, as `tuple_element_producers` builds
its layout index today.

`CoreProductLayoutView` holds field storage for late Core and emission. It is
derived and read-only, built once per late-Core span from the record rows and
the tuple element types that occur, and its documentation names those
sources. It replaces these copies of layout facts:

- `CoreTupleElement` (`ir.brp:2117`): a per-element storage class, recomputed
  for every tuple literal by `prepare`;
- `CoreTupleConstruct.release_mask` (`ir.brp:1718`): which slots are managed,
  again per literal;
- `CoreRecordCowField.field` (`ir.brp:2660`): a full copy of the declaration's
  `CoreHeapRecordField` inside every copy-on-write expression;
- the record-name dictionaries built separately by `record_update.brp:220`,
  `allocation_analysis.brp:335`, `emit_record_layout.brp:193`,
  `c_symbol_projection.brp:867` and `list_layout.brp:54`. Each returns `Option`
  on lookup, so each caller handles a miss the design rules out.

Until the product-type slice the view is keyed as layouts are today, by
record instance name or tuple element types. That slice rekeys it by
`CoreProduct`. The construction slice therefore turns five spelling-keyed
record indexes into one, and the product-type slice removes the last.

### 1.6 Interim predicates before one product type

Slices 1 to 3 land before `ProductType`, when three type forms name a
product: `HeapRecordType(String)`, the inline change's
`InlineRecordType(String)` and `TupleType(List[CoreType])`. Slice 1 added
`stage_09_core/product_type.brp`, and every product question in slices 1 to 3
goes through it:

```
--- A product-shaped type, or `None`. The only function in slices 1 to 3 that
--- matches the three interim product variants.
pure func core_product_of(typ: CoreType) -> Option[CoreInterimProduct]

pure func interim_product_representation(product: CoreInterimProduct) -> CoreProductRepresentation

--- The record instance a record product is, or `None` for a tuple: for C
--- member spelling and for the record-only rewrites not yet extended to
--- tuples (record update paths, field takes).
pure func interim_product_record(product: CoreInterimProduct) -> Option[String]
```

`interim_products_equal` and `interim_product_field_types(rows, product)` are
added with their first callers (slices 2 and 3).

`CoreInterimProduct` is opaque over the three forms: `HeapRecordType` and
`TupleType` are `ManagedBox`; `InlineRecordType` is `InlineValue`. New code in
those slices matches none of the three variants directly. Slice 4 replaces
the bodies with `ProductType` cases, renames the module's types to the final
ones, and deletes the variants, so its change outside the module is the
deletion of old arms.

### 1.7 Equality and hash

Tuple `==` and hashing come from `implements Equatable for (A:Equatable,
B:Equatable)` and its siblings in `standard_library/src/tuple.brp:46`. A record
with no written implementation derives its equality fieldwise: typecheck
decides, once per graph, which records have every field Equatable
(`stage_06_typecheck/headers/derived_record_equality.brp`), and Core lowering
builds their `Equatable` impl from the record's lowered fields
(`lower_derived_record_equality`), so each comparison is an ordinary impl
method that trait resolution and monomorphization treat like a written one.
Tuples derive theirs the same way, element by element, for every arity the
graph has no written implementation of; the impl is lowered beside the
Equatable trait declaration, since a tuple belongs to no module. Seven
written implementations are exactly the derived comparison and stay only until
the bootstrap compiler derives equality, because it compiles the compiler and
the standard library: `SourcePackageLayout`, `LintConstantValue`,
`LintConstantParameterState` and `WorkspaceRoot` in `blorp/src`, and the three
tuple implementations in `tuple.brp`. Delete them after the next bootstrap
rotation. There is still no
identity fallback. Dictionary key callbacks
(`hash_key_callbacks`) reach the resolved implementation the same way for both
families.

Core has no native equality for products. `has_native_structural_equality`
in `trait_resolve.brp` covers only enum tags, `..#N` indices, `Ptr`, numeric
tensors, String and Set, each compared by value. An operator with neither an
implementation target nor one of those types is an internal compiler error
(`UnresolvedOperatorTarget`), never a C `==` on two boxes. Trait default
methods are materialized for generic implementations too, so the
`not_equals` and ordering defaults of `tuple.brp` and of a user `Wrap[T]` are
ordinary implementation methods. No Core pass compares product values by
shape, and none may start to. Enums, refinement indexes and tensors keep
native equality; they are not products.

## 2. Operations

Today, `ir.brp:1771-1774` and `ir.brp:1801-1805`:

```
	ProductFieldExpr(CoreExpr, CoreFieldOrdinal, CoreType, CoreSourceLoc)
	TupleExpr(List[CoreExpr], CoreType, CoreSourceLoc)
	TupleConstructExpr(CoreTupleConstruct, CoreType, CoreSourceLoc)
	...
	RecordExpr(List[CoreRecordFieldValue], CoreType, CoreSourceLoc)
	RecordUpdateExpr(CoreExpr, List[CoreRecordFieldValue], CoreType, CoreSourceLoc)
	RecordReuseExpr(CoreExpr, List[CoreRecordFieldValue], CoreType, CoreSourceLoc)
	RecordCowUpdateExpr(CoreExpr, List[CoreRecordCowField], CoreType, CoreSourceLoc)
	RecordConstructExpr(String, List[CoreRecordFieldValue], CoreType, CoreSourceLoc)
```

with, at `ir.brp:1718`, `ir.brp:2653` and `ir.brp:2660`:

```
record CoreTupleConstruct {
	elements: List[CoreTupleElement],
	release_mask: Int,
	retain_mask: Int
}

record CoreRecordFieldValue {
	name: String,
	ref: CoreFieldRef,
	value: CoreExpr
}

record CoreRecordCowField {
	field: CoreHeapRecordField,
	replacement: Option[CoreExpr]
}
```

Several states here are representable but wrong:

- Pre-ownership `RecordUpdateExpr` now lists only authored replacements in
  written order, using the existing checked field identities. Inheritance is
  implicit. Ownership lowering joins declaration rows to produce complete
  reuse/COW storage rows; it no longer guesses inheritance from expression
  shape. The copied `CoreRecordCowField.field` metadata remains a separate
  cleanup opportunity.
- One list order means both evaluation order and storage order, and `prepare`
  reorders it after Perceus. That was a use-after-free on `main`. The
  `record_literal_order` pass fixed it under the rule this plan adopts, fields
  evaluate in written order and are stored by declared position, by binding
  an out-of-order literal's field values to variables before Perceus. It
  adds 0.59% to the self-compile's allocations and 0.22% to its retired
  instructions (`benchmarks/results/record_literal_order_pass_2026-10-06.md`);
  the construction form here replaces it. Updates now follow written order
  independently of the construction migration: sparse replacements remain
  attached directly to their base carrier until `record_update_ownership`.
  That pass preserves direct evaluation when checked declaration positions
  already increase, otherwise stages replacement values in written order.
  Nested layers stage before the final owner transfer, keeping superseded
  side effects and in-place reuse. The runtime regression is
  `blorp/test/test_runtime/test_types/test_record_update_field_order.brp`.
- `prepare_tuple_expr` can fail to classify a tuple and fall back to a
  `TupleExpr` that reaches the backend.
- `retain_mask` is a second ownership mechanism. `prepare` sets it after
  Perceus from an expression's shape (`tuple_pointer_expr_needs_retain`,
  `prepare.brp:2276`), while record fields get explicit retains from Perceus.

After:

```
	ProductExpr(CoreProductBuild, CoreType, CoreSourceLoc)
	ProductFieldExpr(CoreExpr, CoreFieldOrdinal, CoreType, CoreSourceLoc)
	ProductUpdateExpr(CoreExpr, CoreProductReplacements, CoreType, CoreSourceLoc)
	ProductReuseExpr(CoreVar, CoreProductBuild, CoreType, CoreSourceLoc)
	ProductCowUpdateExpr(CoreVar, CoreProductCowPlan, CoreType, CoreSourceLoc)
	MultiValueExpr(List[CoreExpr], CoreType, CoreSourceLoc)
	UnpackLetExpr(List[CoreVar], CoreExpr, CoreExpr, CoreType, CoreSourceLoc)


record CoreProductFieldValue {
	ordinal: CoreFieldOrdinal,
	value: CoreExpr
}


--- Every field of the product exactly once. List order is evaluation order;
--- each value names the ordinal it is stored at. Built only by
--- `product_build`, which checks the ordinals against the product's layout.
opaque type CoreProductBuild = List[CoreProductFieldValue]


--- The replaced fields of an update: at least one, each ordinal at most once,
--- in evaluation order. Every other field is inherited from the base.
opaque type CoreProductReplacements = List[CoreProductFieldValue]


--- One entry per field, in ordinal order: `None` keeps the base's field.
--- Field types and release policies come from the layout view.
opaque type CoreProductCowPlan = List[Option[CoreExpr]]
```

Notes on the new forms:

- `ProductReuseExpr` and `ProductCowUpdateExpr` take a `CoreVar`. Their base is
  the owner whose storage is reused: `reuse.brp:2308` builds it from the
  dropped variable, and `record_update.brp:330` forwards the transferred
  owner. The slice that introduces them confirms that each producer passes a
  variable and binds any other form first.
- `MultiValueExpr` builds a multi-value from elements in element order, and
  evaluates them in that order. Scalar replacement creates it and binds any
  element written earlier in source order to a temporary first.
- `CowFieldTakeRetainPolicy(CoreVar, String, CoreFieldRef, String)` becomes
  `CowFieldTakeRetainPolicy(CoreVar, CoreFieldOrdinal)`, since the record and
  field spellings are derivable.
- `TupleFieldSemanticMatchAccessor` and `TupleFieldAccessor` became
  `ProductFieldSemanticMatchAccessor` and `ProductFieldAccessor` in slice 1.
  That adds no record patterns; it only removes the tuple-only spelling.
- Perceus treats every managed product field operand as it treats a record
  field operand today. It retains a borrowed operand and moves an owned one at
  its last use. `retain_mask` is deleted; the release mask comes from the
  layout view.

## 3. Shared optimizations

### 3.1 Scalar replacement of managed products

Increment 1's `tuple_flatten` and increment 2's call boundaries become one
pass over every `ManagedBox` product. A product binder is a group of element
locals unless it is used whole at a sink. Where its elements are needed, a
source box keeps its box and its projections borrow from it.

The [parked record pilot](FIXED_LAYOUT_ROADMAP.md#s5-decide-which-layout-optimizations-are-worth-reintroducing)
found zero eligible sites because it excluded the cases below. Each is
admitted or given a defined boundary:

- **Non-literal right-hand sides** (arms that build the product, a call
  returning a multi-value, an update of a flattened product). The producer
  runs once, in order, into element binders; nothing observes the product
  except through its elements.
- **Aliases.** `b = a` names the same group, and a whole use of `b` counts
  against `a`. Immutable values cannot observe one another.
- **Whole-value uses.** A call passes elements to a flattened parameter (a
  least fixpoint over the monomorphized call graph boxes a parameter that
  reaches a sink), a return yields a multi-value, and a store, runtime helper
  or boxed parameter builds one box at the use. The rebuilt box is equal to
  the original by value semantics, and no box is added except at counted,
  pinned re-box sites (section 3.2).
- **Managed fields.** Each element local owns its value and Perceus balances
  elements one by one. In `{ r | names = r.names.append(x) }` on a flattened
  `r`, the list's own reference count decides whether the append is in
  place, as it does for the slot of a unique box.
- **Implementation methods** are ordinary functions after mono. A method the
  runtime calls back (`RuntimeCallbackMethod`) keeps boxed parameters.
- **Globals** are source boxes; reads borrow from them.
- **Captures** take elements by value. A lambda's own parameters keep the
  closure ABI's box, and references to flattened functions go through real
  adapters (section 4).
- **`var` products** unpack to temporaries before assigning each element.
  Each managed element has its own cancellation slot, and `break`,
  `continue`, `?=`, resource exits and tail-recursion jumps are edges of the
  use analysis.
- **Identity builtins.** An operand of `same_object`, `is_unique` or
  `refcount` is a sink, for every managed product, so the builtins answer as
  they do today and the compiler's own `same_object` "unchanged" checks keep
  their meaning. This replaces increment 2's rule that answered `False`,
  `True`, `0` for a flattened tuple. On an inline product they are a compile
  error (decision 14).
- **Boundaries.** A record with a declared native ABI stays boxed at its
  adapters. A product with more data members than the multi-value limit
  (decision 3) is boxed at call boundaries but may be flattened as a local.
  Neither branches on the family.

Core today, rendered from `bin/blorp compile --no-format
--dump-core-after=specialize` on `main` (immediately after `tuple_flatten`):

```
func advance(cursor#87: HeapRecord Cursor, byte#103: Int) -> HeapRecord Cursor:
    if (byte#103 == 10):
        Record{offset = (cursor#87.offset + 1), line = (cursor#87.line + 1), column = 1}
    else:
        Record{offset = (cursor#87.offset + 1), line = cursor#87.line, column = (cursor#87.column + 1)}

func cursor_at(target#431: Int) -> HeapRecord Cursor:
    var cursor#463: HeapRecord Cursor = Record{offset = 0, line = 1, column = 1}
    while (cursor#463.offset < target#431):
        cursor#463 := advance(cursor#463, byte_at(cursor#463.offset))
    cursor#463
```

The tuple twin is boxed the same way on `main`, because increment 1 does not
reach calls. The increment 2 branch already compiles the tuple twin to
element parameters, an `unpack` and a multi-value result. After the scalar
replacement slice the record version produces the same Core, spelled with the
unified forms:

```
func advance(cursor.offset: Int, cursor.line: Int, cursor.column: Int, byte: Int) -> MultiValue(Int, Int, Int):
    if (byte == 10):
        MultiValue((cursor.offset + 1), (cursor.line + 1), 1)
    else:
        MultiValue((cursor.offset + 1), cursor.line, (cursor.column + 1))

func cursor_at(target: Int) -> MultiValue(Int, Int, Int):
    var cursor.offset: Int = 0
    var cursor.line: Int = 1
    var cursor.column: Int = 1
    while (cursor.offset < target):
        unpack (next.offset, next.line, next.column) = advance(cursor.offset, cursor.line, cursor.column, byte_at(cursor.offset))
        cursor.offset := next.offset
        cursor.line := next.line
        cursor.column := next.column
    MultiValue(cursor.offset, cursor.line, cursor.column)
```

In C, `main` calls `brp_ty1_make(...)` in `advance` on every iteration and
keeps a cancellation cleanup frame for the managed loop variable. The
increment 2 branch emits the tuple twin as a by-value struct with no
allocation and no cleanup frame:

```c
typedef struct blorp_mv_0 { long e0; long e1; long e2; } blorp_mv_0;
static blorp_mv_0 brp_22(long brp_vn_1, long brp_vn_2, long brp_vn_3, long brp_v_aO);
...
blorp_mv_0 __unpacked_4 = ({ ... brp_22(__t0_0, __t0_1, __t0_2, __t0_3); });
long brp_vn_4 = __unpacked_4.e0;
```

Pass changes beyond increment 2's code:

- Product tests replace `is_tuple_type`.
- Element types come from `product_layout`.
- `ProductFieldExpr` replaces both projections, and record update of a
  flattened base becomes element rebinding.
- The retype walk that first makes every tuple a `BoxedTupleType` is deleted,
  because a box is already the default `ProductType`.

### 3.2 Multi-value parameters and results

Increment 2's rules carry over unchanged for managed products: sink and
source boxes, the boxed-parameter fixpoint, function-reference adapters,
per-element ownership, shared drop carriers, and element temporaries only
where an element is not a plain read. Two rules need a product-wide decision:

- **Mixed results.** A result is mixed when some path returns an existing box,
  as `source_advance`'s `None: cursor` arm does. If the parameter is
  flattened, that path returns elements and is not mixed. If it is a real
  source box, increment 2 still returns a multi-value, and a caller that stores
  the result rebuilds a box. Records are stored much more often than tuples, so
  the rule becomes: return a multi-value only when no caller stores the
  result whole. The same call-graph fixpoint decides it, and the rule applies
  to tuples too. Increment 2's census found zero such stores for tuples in the
  self-compile, so tuple parity should hold; the slice measures it.
- **Size.** Decision 3 limits the data members of a multi-value parameter
  or result. Tuples have at most four. The census's leading records have two to
  five fields.

### 3.3 Reuse and copy-on-write for tuples

Tuples have no update syntax, so they gain two things:

- **Drop-then-build reuse.** `heap_record_reuse_compatible`
  (`reuse.brp:1592`) compares record names. It becomes `products_equal`, so a
  dropped tuple box is reused for a new tuple of the same product. Soundness
  is unchanged: Perceus's adjacent drop proves the owner dies with the new
  value; the runtime uniqueness check guards the reuse; field values are
  evaluated before the old fields are destroyed. Cross-family reuse, a record
  box for an equal-layout tuple, is excluded because the object's installed
  type and destructor differ.
- **Rebuild from projections.** A `ProductExpr` whose fields at some ordinals
  are `ProductFieldExpr(v, same ordinal)` of a dying product `v` of the same
  product is an update of `v`. It becomes `ProductReuseExpr` or
  `ProductCowUpdateExpr`, so `(t[0], f(t[1]))` and a hand-written full record
  literal both update in place. Soundness is that of record updates: the
  source dies at the construction, every replacement value is evaluated before
  the source is consumed, and the same field-take rules apply.

Both depend on the runtime slice's typed tuple layouts, which give tuples the
record reuse helper. Measure a census of dynamic reach before building the
rebuild rule.

## 4. Runtime and backend

Records today are one typed struct per instance with a `_make` constructor,
a destroy function and `__blorp_reuse_record_<type>`. Fields are ordinals
(`f0`, `f1`), except declared native ABI records, which keep source member
names. Tuples are `blorp_Tuple` (`runtime_decl.c:701`):

```c
typedef struct { blorp_Object header; long arity; long release_mask; void* elem[]; } blorp_Tuple;
```

`blorp_tuple_new(long arity, ...)` is a varargs call. Elements are `void*`
slots: integers and floats are bit-cast into them, but an inline struct such
as a stack `Option` gets its own `blorp_box_struct` allocation
(`runtime_decl.c:1420`). Measured with `--memory-stats`, a two-element
`List[(Int, Option[Int])]` allocates 5 objects and the equivalent
`List[Slot]`, `record Slot { key: Int, value: Option[Int] }`, allocates 3.

Convergence (the runtime slice):

- **Typed tuple layouts.** The record layout emitter emits a managed tuple box
  as a typed struct keyed by its product layout. Inline-struct elements are
  stored inline, `_make` takes typed arguments, and the destroy and reuse
  helpers come from the same code as records'. `prepared_tuple_renderer.brp`,
  the `emit_tuple_*` functions, the `static_tuple_*` initializers and the
  runtime's `blorp_tuple_new`, `blorp_tuple_set_rc` and
  `blorp_tuple_destructor` are deleted.
- **Runtime producers are the boundary.** The runtime builds or reads tuple
  boxes in `blorp_dict_entries`, `blorp_vector_zip`, the stream `enumerate`
  and `unfold` pulls, and the process functions. These move first, each
  measured on its own: the collection helpers to standard-library Blorp, the
  process options and results to declared-ABI records (decision 5).
- **Multi-value transport.** `blorp_mv_<n>` structs are C vocabulary for
  by-value returns, shared by every product with the same element C types.
  Initialize every member, and evaluate elements into temporaries left to
  right; C does not sequence initializer-list evaluation. No padding byte is
  compared, hashed or copied as data. Key the registry by element types now
  and by interned type identity when Core types are interned.
- **Native ABI.** Unchanged and only a boundary. A declared native ABI selects
  adapters; a product's shape never selects a C by-value ABI. A multi-value
  struct is never a foreign ABI, and a function reference to a flattened
  function is a real adapter, never a cast to a pointer of another signature.
- **Sums.** `Option`, `Result` and unions keep their representations, nullable
  and tagged specializations and active-payload cleanup.

## 5. Migration in landable slices

Each slice is one reviewed change and preserves behavior. Slices 1 and 2 are
mechanical and mostly delete code; they come first so the increment 2 port and
every later slice are written once, against the unified forms. Line estimates
come from counted match arms and function spans in the current tree; the
increment 2 port's figures come from that branch's diff of `blorp/src`.

| Slice | Deletes | Adds | Emitted C |
| --- | ---: | ---: | --- |
| 1. One projection form | ~450 | ~150 | identical |
| 2. One construction form | ~1,800 | ~500 | records identical except the order fix; tuples move retains |
| 3. Scalar replacement of managed products | ~2,200 | ~7,000 | changes (optimization) |
| 4. One product type | ~600 | ~350 | identical |
| 5. Typed tuple boxes | ~700 | ~350 | changes (layout) |
| 6. Tuple reuse and copy-on-write | ~100 | ~250 | changes where reuse applies |

Slices 1, 2, 4, 5 and 6 together delete about 3,650 lines and add about 1,600.
Slice 3's port is about 400 lines smaller than increment 2 as written (+6,824 /
−2,168 in `blorp/src`), because the `BoxedTupleType` retype walk and its arms
are gone. Admitting records then costs about 600 lines, where a parallel
record pass would cost several thousand.

### Slice 1 (landed). One projection form

`ProductFieldExpr(base, ordinal)` replaced `FieldExpr` and `TupleFieldExpr`.
Core had spelled a module-qualified name (`alias.member`) as a `FieldExpr` over
a `Module`-typed variable, so it first gained its own pre-resolve form,
`ModuleMemberExpr`, built from typecheck's own `TypedModuleMemberExpr`.
Self-compile C was byte-identical. Measured in `blorp/src` the slice is net −4
lines (+1,259/−1,263): the two module member forms and the row-order assertion
added about 120, and the projection removed about 125, against this plan's
estimate of −450/+150. The record-row plumbing for ordinals and the interim
predicates account for most of the difference.

Follow-ups: typecheck publishing a tuple selection's index in
`ResolvedFieldIdentity` would remove the one parse of the selection text in
`product_field_ordinal`; and record update paths and field takes stay
record-only (through `interim_product_record`) until slice 3 decides them for
tuples.

### Slice 2. One construction form

Land in two reviewed changes:

1. **Records.** `ProductExpr` replaces `RecordExpr` and
   `RecordConstructExpr`. Field values carry ordinals, and `prepare` stops
   reordering. Emission evaluates in list order and stores by ordinal, which
   is the written-order rule (decision 1) with no extra code.
2. **Tuples.** `ProductExpr` replaces `TupleExpr` and `TupleConstructExpr`.
   Perceus retains borrowed element operands like record fields.
   `retain_mask`, `tuple_pointer_expr_needs_retain`,
   `normalize_borrowed_tuple_elements` and `CoreTupleElement` are deleted.
   Slot storage classes and the release mask come from the layout view
   (section 1.5).

Today the traversal repeats the same arm for each form, at
`stage_09_core/traverse.brp:2617` and `:2629`, and again for `RecordExpr` and
`RecordConstructExpr`:

```
		TupleExpr(items, typ, loc):
			mapped_items: Option[List[CoreExpr]] = map_context_exprs(items, context, mapper)
			mapped_typ: CoreType = map_context_type(context, mapper, type_mapper, typ)

			if mapped_items.is_none() and same_object(mapped_typ, typ):
				expr
			else:
				TupleExpr(mapped_items.get_or(items), mapped_typ, loc)
		TupleConstructExpr(construct, typ, loc):
			mapped_elements: Option[List[CoreTupleElement]] = map_context_tuple_elements(
				construct.elements,
				context,
				mapper,
			)
			...
```

After, one arm:

```
		ProductExpr(build, typ, loc):
			mapped_build: Option[CoreProductBuild] = map_context_product_build(build, context, mapper)
			mapped_typ: CoreType = map_context_type(context, mapper, type_mapper, typ)

			if mapped_build.is_none() and same_object(mapped_typ, typ):
				expr
			else:
				ProductExpr(mapped_build.get_or(build), mapped_typ, loc)
```

`prepare` today reorders record fields after ownership
(`stage_09_core/prepare.brp:3213`). After, there is nothing to prepare: the
build already holds its ordinals and the type names its layout.
`prepare_record_expr`,
`prepare_record_construct_expr`, `declaration_ordered_record_fields`,
`same_record_field_order` and `prepare_tuple_expr` are deleted.

Change 1 also deletes the `record_literal_order` pass, which the ordinals make
redundant:

- `bind_record_literal_fields_in_written_order` and its helpers in
  `prepare.brp`, `run_record_literal_order_pass`, `RECORD_LITERAL_ORDER_PASS`
  and its entries in both pass lists in `pipeline.brp`;
- `RecordLiteralFieldTemp` and `RECORD_LITERAL_FIELD_TEMP_ORIGIN` in `ir.brp`;
- the two `RECORD_LITERAL_FIELD_NAME_PREFIX` lines in
  `scripts/check-magic-spellings.allowlist`;
- the `run_record_literal_order_pass` step in
  `benchmarks/blorp/profiles/perceus_allocations.brp` and its mention in
  `benchmarks/README.md`;
- the "Record Literal Field Order" section of `docs/OWNERSHIP_MODEL.md` and
  the pass's line in `docs/ARCHITECTURE.md`;
- the pass's unit tests in `test_core_prepare.brp` and
  `test_core_pipeline.brp`. The runtime cases in
  `test_record_literal_field_order.brp` stay: they pin the rule.

Evidence:

- C identity for records against a base that includes the written-order fix.
- For tuples, an exact retain/release and allocation oracle with equal counts
  per fixture: the retains move from inline mask code to explicit dups.
- The ownership-shape probes and the Perceus suites.
- `scripts/test compiler-core-sanitize` and `leak`.
- The stage-2/3 fixpoint.

### Slice 3. Scalar replacement of managed products

This is the first optimization slice. It generalizes increments 1 and 2 to
every `ManagedBox` product: locals and match subjects, `var` loops, call
parameters and results. It lands as two reviewed changes:

1. **Port increment 2.** Port its machinery onto the unified forms with
   structural products only:
   - `MultiValueType`, `MultiValueExpr` and `UnpackLetExpr` replace the
     dual-meaning `TupleType`;
   - `BoxedTupleType` and its retype walk are deleted;
   - the Perceus-ingress multi-value check stays on for every compile
     (decision 7).

   Behavior matches the increment 2 branch.
2. **Admit records.** Admit nominal products, with the declared-ABI and size
   boundaries of section 3.1, the mixed-result rule of section 3.2 and a
   re-box census counter.

Acceptance:

One method for every comparison: stage-2 `-O2` compilers on one frozen input,
run serially. Allocations are exact counts from the diagnostic link.
Instructions are the median of five interleaved runs per compiler, with a
tolerance of 1.0%, twice the observed median drift of about 0.5%. "No
regression" means within that tolerance.

- **Port, parity with increment 2.** Count `blorp_tuple_new` calls by arity
  with a counting runtime copy, as the increment 2 measurement did. Tuple
  allocations fall by at least 46.6% against the parent. Total allocations are
  no worse than the parent's, and instructions show no regression. The port
  may land before records are admitted on that basis; increment 2's +0.68% is
  within the tolerance.
- **Records, the `Cursor` win automatically.** The loops are in the
  compiler's own source, so each compiler under test builds two stage-2
  compilers from one frozen input: one with
  [`cursor_original_loops_managed.patch`](../benchmarks/results/product_unification/README.md)
  applied (the original `var cursor` / `source_advance` loops, `Cursor` spelled
  `record` so the inline representation does not apply) and one without it.
  The control is the parent's pair: D is the parent's patched allocations
  minus its unpatched allocations, the gap the hand-written scanner closed.
  The candidate's own gap, its patched minus its unpatched allocations, must
  be at most 1% of D, and its patched build's instructions show no regression
  against its unpatched build. Savings elsewhere do not count toward the gap
  because both builds share them. Repeat without the `record` respelling,
  where the inline change already removes the gap; the candidate's gap must
  stay within the same residual.
- **Records, census.** A per-type maker census (the census report's method)
  shows the fall for the small managed records it ranks, such as
  `CoreMapState` and `OwnershipUseSummary`. The re-box counter reports boxes
  built from multi-value records at sinks. A census of record-typed operands
  of `same_object`, `is_unique` and `refcount` reports how many records stay
  boxed because of them. Accept only with a net allocation fall and no
  instruction regression.
- **Shape fixtures.** Exact allocation oracles pin the loop of section 3.1 (0
  allocations per iteration for a managed record), each eligibility case in
  section 3.1, each re-box shape, and value tests for `(b, b)`, updates of a
  flattened managed field, and `var` products across `continue` and
  cancellation.
- **Gates.** The common gates of
  [`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md#soundness-and-common-gates),
  generated-C review, the codegen audit and the stage-2/3 fixpoint.

### Slice 4. One product type

This waits on declaration/use identity (item 1 of the fixed-layout roadmap).

- `ProductType(CoreProduct)` replaces `HeapRecordType` and
  `InlineRecordType`, `TupleType` is renamed `SourceTupleType` and allowed
  only before the representation pass, and the interim predicates of section
  1.6 swap their bodies.
- `CoreRecordRef` is issued from checked identity, and the layout view is
  keyed by `CoreProduct`.
- The arms that list `HeapRecordType(_) | TupleType(_)`, and the paired arms,
  merge.
- The remaining spelling-keyed record lookups and their `Option` misses are
  deleted.

Evidence:

- byte-identical self-compile C;
- fixtures with same-spelled records in two modules and a local declaration
  sharing a prelude name, the record form of the `Option` collision;
- an identity census showing no record spelling lookup after lowering.

### Slice 5. Typed tuple boxes

Do this as section 4 describes. First move the runtime tuple producers to
standard-library Blorp or declared-ABI records, measuring each one. Then emit
managed tuple boxes through the record layout emitter.

Evidence:

- generated-C review;
- the codegen audit with deliberately updated tuple fixtures;
- exact allocation oracles (the `List[(Int, Option[Int])]` case drops from 5
  to 3);
- runtime and leak gates;
- matched stage-2 allocations and instructions.

After this slice, a scalar-only tuple can take the inline representation
(open decision 6).

Bootstrap: `bin/blorp` is built by the pinned bootstrap, whose emitted C calls
`blorp_tuple_new`, `blorp_tuple_set_rc` and `blorp_tuple_destructor` for the
compiler's own tuples. Those three stay in the runtime until a rotation after
this slice, then are deleted. Moving dictionary entries, zip and enumerate to
standard-library Blorp needs no rotation if it uses only builtins the pin
knows. The process records need one only if a builtin the compiler itself
calls changes its name or signature; keep those signatures and adapt at the
boundary to avoid it.

### Slice 6. Tuple reuse and copy-on-write

Measure a census of drop-then-build tuple pairs and of rebuild-from-projection
sites first. Then add identity-keyed reuse (section 3.3), and add the rebuild
rule only if the census shows dynamic reach. The evidence is the same as for
any reuse change:

- value semantics for a shared source;
- ASan for a borrowed projection that outlives the build;
- exact allocation oracles;
- the fixpoint.

### After the slices

Increments 3 (consuming clones with multi-value results), 4 (one last-use
analysis) and 5 (field places) of
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md) apply
to products as written. Their place keys become binder ids and field
ordinals. Increment 7 (stored tuples) becomes stored products, and its census
covers records and tuples together.

## 6. Increment 2: what is reused and the rebase plan

Branch `core/multi-value-results` is paused at a clean, re-reviewed commit.
Its ownership logic was found sound; tests, docs and a green gate remain. On
`blorp/src` it is +6,824 / −2,168 lines over 52 files. Everything except the
items below is reused with renames only: `tuple_abi.brp`, the flattening in
`tuple_flatten.brp`, the Perceus per-element balance and shared drop
carriers, cancellation slots, multi-value emission, function-reference
adapters and the tests.

Replaced: `BoxedTupleType`, its JSON tag and retype walk
(`boxed_tuples_in_type`, `declaration_types_retyped`, the `mono_substitute.brp`
additions) are deleted; multi-value `TupleExpr` and `TupleType` become
`MultiValueExpr` and `MultiValueType`; `TupleFieldExpr` becomes
`ProductFieldExpr`; and the identity-builtin answer becomes a sink
(decision 12).

Rebase plan:

1. Land slices 1 and 2 on `main`. Do not merge `main` into the paused branch
   meanwhile.
2. Take the paused branch's net diff
   (`git diff origin/main...core/multi-value-results`) as a tree, and run the
   slice 1 and slice 2 codemods over it first, so it speaks the unified forms.
   Applying the raw diff to `main` after slice 2 would conflict on every
   renamed arm.
3. Apply the converted diff on a fresh branch from `main`, apply the
   increment 2 renames above, and delete the retype walk by hand.
4. Run increment 2's own tests unchanged first. They pin values, allocations
   and C shapes rather than Core spellings, so they are the parity oracle.
   Then run the slice 3 acceptance.
5. Recheck the Linux `-O0` stack frames at 1,000 nesting levels with
   `-fstack-usage` after records are admitted, because records add
   parameters.

Close the paused branch once the port lands.

## 7. M6 implications

Discovery M6 makes the tree path the default and deletes `tables/`. It waited
on value-tuple increments 1 to 4, and on increment 5 if a re-measured M0 needs
it. Under this plan its prerequisites are:

| Before | After |
| --- | --- |
| Increment 1 | on `main`; becomes part of slice 3 |
| Increment 2 | slices 1 and 2, and slice 3's port of increment 2 |
| Increment 3 | increment 3, stated for products |
| Increment 4 | increment 4, stated for products |
| Increment 5 if M0 needs it | unchanged |

Slice 3's record admission, slices 4 to 6, and the inline fixed-record change
are not prerequisites. They may lower the parser's cost, which helps meet the
ceiling, but that is not assumed.

M6 moves later by the time it takes to land slices 1 and 2 before the port. It
cannot move earlier: nothing here cuts the hand-off cost before the port
lands, and the ceiling is unchanged.

## 8. Risks and decisions

Risks, with mitigations:

- **Merge conflicts.** Slices 1 and 2 are wide renames that touch the
  identity candidate, the inline branch and the port. Land them early as
  scripted, C-identical renames.
- **Re-boxing.** Records reach sinks more often than tuples. The
  mixed-result rule, the re-box counter and net-allocation acceptance bound it.
- **Stack growth at `-O0`.** More parameters grow frames, as increment 2 found
  on Linux. The size limit and `-fstack-usage` checks bound it.
- **Compile time.** Wider fixpoints; skip declarations with no managed product
  type, as increment 2 skips tuple-free ones, and measure.
- **Identity.** Issue `CoreRecordRef` only from issued identity, never from
  decoded or standalone states.
- **Debuggability.** Element locals are named from the binder and ordinal, and
  dumps print `cursor.offset` from the row.

Owner decisions (Keith), including the open ones:

- **1. Field evaluation order.** Decided: Rust's rule. Record-literal fields are
  evaluated in written order and stored by declared position. The fix on
  `main`, the `record_literal_order` pass, landed before this plan's slices.
- **2. Increment 2 landing order.** Decided: rebase increment 2 onto slices 1
  and 2 rather than land it first.
- **6. Inline scalar tuples.** Open. Making a tuple whose elements pass the
  inline eligibility test inline implicitly, after slice 5, applies the same
  plain-data rule as fixed records with no `fixed` promise to check. It
  depends on decision 14, now decided. Recommendation: adopt it.
- **14. Identity builtins on inline products.** Decided by Keith
  (2026-10-06): a compile error. An inline value has no allocation, so
  `same_object`, `is_unique` and `refcount` have no truthful answer for it.
  Representation is decided after monomorphization, so the inline fixed-record
  change reports the error there (`record_representation`,
  `error[inline_record_identity]` with a help line), not in typecheck; inline
  tuples will use the same check.

Team decisions, taken as recommended or as the coordinator decided:

- **3. Multi-value size limit.** Four data members to start, the tuple maximum;
  measure five to eight on the census types before raising it, because
  frames grow with members.
- **4. Results where a path returns an existing box.** A multi-value only when
  no caller stores the result whole, for tuples too; records are stored far
  more often, and increment 2's census shows the rule keeps tuple parity.
- **5. Runtime tuple producers.** Standard-library Blorp for dictionary entries,
  zip and enumerate, and declared-ABI records for the process API, so no
  second runtime tuple layout survives.
- **7. Multi-value ingress check.** Stays on for every compile. Nesting a
  `MultiValueType` or binding one to a variable stays representable in the
  types, and the check is the only guard against it; safety comes first,
  at about 0.4 M allocations per self-compile.
- **8. Tuple reuse rules.** Identity-keyed reuse lands; the rebuild-from-
  projections rule waits for a census that shows dynamic reach.
- **9. Plan ownership.** This plan owns the Core product model, scalar
  replacement and multi-values; the tuple plan keeps increments 3, 4, 5 and
  7 for products, so each rule has one home.
- **10. Multi-values and inline products.** Merging `MultiValueType` into inline
  structural products is parked until inline products may own managed
  children under the checked fixed contract.
- **11. Range.** `Range` becomes an inline product read with `ProductFieldExpr`;
  it is an all-`Int` fixed record, so no form of its own is needed.
- **12. Identity builtins on managed products.** An identity-builtin operand is
  a sink, so no user-visible result changes for a managed product and the
  compiler's `same_object` checks keep their meaning.
- **13. Inline eligibility.** Numbers, `Char` and eligible fixed records; `Bool`
  waits for fixed unions.

## 9. Verification

Start each slice with its owning suite and `scripts/compiler-check --changed
--plan`. Slices that keep C byte-identical use the `--require-identical`
self-compile protocol. Slices that change C run:

- generated-C review and the codegen audit;
- the allocation oracle and the ownership-shape probes;
- `scripts/test compiler-core-sanitize`, `leak` and `runtime`;
- `scripts/compiler-fixpoint` at `-O2`;
- matched stage-2 allocations and retired instructions on a frozen input.

The full command list is in
[`VALUE_TUPLES_AND_STATE_HANDOFF.md`](VALUE_TUPLES_AND_STATE_HANDOFF.md#soundness-and-common-gates).
Put raw measurements in `benchmarks/results/` and link them from the slice's
commit body. Delete each slice from this plan when it lands.
