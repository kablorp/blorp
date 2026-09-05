# Blorp Memory Model

Blorp exposes value semantics. Assignment copies a logical value, mutable names
rebind, and no source construct exposes shared mutable state. The compiler and
runtime implement those semantics with stack values, atomic reference counting
(ARC), and copy-on-write (COW).

Write code against the value model. Allocation reuse and representation are
implementation details unless profiling shows that a particular pattern is
material.

## Bindings

Bindings are immutable by default:

```blorp
x: Int = 5
name = "Ada"
```

`var` permits local rebinding:

```blorp
var total: Int = 0
for value in values:
	total += value
```

Rebinding changes the value associated with that local name. It does not mutate
another alias or expose a shared mutable location. Local mutation is allowed in
pure functions because it cannot be observed outside the call.

Closures capture immutable values by value. Capturing a mutable local is a
compile error; explicit state should be threaded through values instead.

## Value Families

### Inline Values

Primitive scalars, enums, opaque scalar representations, and valid `struct`
values are copied directly. A struct is unmanaged and therefore may contain
only fields with valid inline unmanaged representation.

### Managed Values

Strings, lists, dictionaries, sets, tensors, heap records, payload unions,
closures with captures, channels, and other runtime objects are managed by ARC.
Copying one of these values creates another logical owner of the same immutable
value.

The runtime may share storage while no mutation is visible. A consuming update
operation checks whether storage is uniquely owned:

- unique storage may be updated or grown in place;
- shared storage is copied before the update; and
- the operation returns the new logical value in either case.

That is why update results must be rebound:

```blorp
var items: List[Int] = []
items = items.append(1)
items = items.append(2)
```

Ignoring the returned value leaves `items` unchanged at the source level.

## Records And Structs

`record` values are managed heap values with COW behavior. Record update always
creates a new logical value:

```blorp
record Point { x: Int, y: Int }

p: Point = { x = 1, y = 2 }
q: Point = { p | x = 10 }
```

`p` remains `{x = 1, y = 2}` and `q` is `{x = 10, y = 2}`. The compiler may
reuse `p`'s allocation when ownership proves no other live value can observe it.

`struct` values are inline and unmanaged. They are appropriate for small value
records whose complete field graph is inline. Field declaration order remains
source order; ordinary C alignment and padding apply.

## Option And Result

`Option[T]` and `Result[T, E]` have value semantics independent of their chosen
runtime layout. The compiler may use an inline tagged value, a nullable-pointer
representation, or a managed payload representation when the complete concrete
types are known.

Code must not depend on tag widths, null-pointer encoding, or generated C
shape. Pattern matching is the source-level access boundary.

## Collections

Collections are persistent values implemented with COW where practical:

```blorp
original: List[Int] = [1, 2]
updated: List[Int] = original.append(3)
```

`original` remains `[1, 2]`. `updated` may share storage initially or may use a
new allocation; the result is observationally the same.

For hot builders, keep one mutable local owner and rebind each update. Creating
an extra alias before the mutation sequence can force copies because the
runtime must preserve both logical values.

Empty list literals may share immortal, layout-specific backing storage. They
therefore require no managed allocation when evaluated. The first operation
that adds an element observes the immortal object as nonunique and allocates an
ordinary writable list through the same COW path used for other shared lists.
This representation is not observable through ordinary list value semantics;
ownership instrumentation such as `memory.is_unique([])` reports `False`.

```blorp
var result: List[Int] = []
for value in values:
	if keep(value):
		result = result.append(transform(value))
result
```

Prefer `map`, `filter`, or `filter_map` when they express the operation more
directly. Use an explicit builder loop when control flow or error handling makes
that clearer.

## String Literals

Value-position string literals are immutable artifact data. Equal literal byte
sequences share one statically initialized `String` object within the generated
artifact. They do not allocate at runtime and are not included in `MemStats` or
leak counts.

The static object uses the normal `String` ABI, so equality, length, byte
access, `refcount`, and `size_of` behave like other strings. Its refcount is the
runtime immortal sentinel and `is_unique(literal)` is `False`. A mutating COW
operation therefore allocates a normal mortal copy before writing; later uses
of the literal continue to observe the original bytes.

Only source literals have this storage class. Interpolation, concatenation,
formatting, `to_string`, and foreign-returned strings remain mortal managed
allocations and remain visible to memory instrumentation.

## Tensors And Fixed Shapes

Tensor and fixed-shape vector values use managed runtime storage unless a Core
optimization proves a narrower representation. Operations return new logical
values and may reuse uniquely owned storage internally.

`set_index` remains fallible because its index is checked at runtime:

```blorp
match values.set_index(index, replacement):
	Some(updated):
		use(updated)
	None:
		handle_bad_index()
```

Compile-time range proofs and static tensor dimensions may eliminate checks,
but they do not change source-level value semantics.

## Closures

A closure captures a snapshot of each immutable captured value. Managed
captures remain alive as long as the closure needs them. Calling or copying the
closure cannot expose mutation of the original binding.

Zero-capture closures may use static runtime descriptors. Capturing closures
normally allocate an environment containing retained managed captures and
copied inline captures.

## Recursive Data

Blorp has no source-level cyclic data. Recursive types must cross a valid base
case or indirection such as a union, `Option`, or collection:

```blorp
record Node {
	value: Int,
	next: Option[Node]
}
```

An infinitely inline record/struct product is rejected during type-header
validation. The absence of cycles is what lets ARC reclaim values without a
cycle collector.

## Concurrency

Tasks receive values, not shared mutable references. Managed values use atomic
reference counts because ownership can cross scheduler threads, while source
semantics remain immutable. Communication occurs through channels and
structured task results.

Resource handles are a separate scoped capability category. They cannot be
copied into ordinary values or escape their owning scope. See
[CONCURRENCY_AND_RESOURCES.md](CONCURRENCY_AND_RESOURCES.md).

## Performance Guidance

Start with clear value-oriented code, then use `--profile` and `--leak-check`.
The most useful patterns are:

- keep a single mutable local owner while building a collection;
- avoid retaining old aggregate versions in a hot update loop unless needed;
- use direct iteration rather than repeated indexed list lookup;
- use `@tail_recursive` only for verified tail-recursive algorithms; and
- prefer collection combinators when they avoid manual intermediate builders.

Do not infer allocation behavior from source syntax alone. Core specialization,
ownership, reuse, scalar replacement, and the C optimizer can all change the
physical representation while preserving the same source result.

## Compiler Contract

The implementation uses explicit owned, borrowed, consumed, transferred,
duplicated, and dropped values. COW operations consume their receiver owner and
return an owner for the result. Static constants and zero-capture closures have
separate rules that are not visible in source semantics.

Those details are normative for compiler and runtime work in
[OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md). Generated C examples belong in tests
and codegen audits, where they are checked against the current backend, rather
than in this user-facing document.
