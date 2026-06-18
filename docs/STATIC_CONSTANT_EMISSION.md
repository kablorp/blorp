# Static Emission for Compile-Time Constants

## Status

This document records the backend direction for Blorp global constants whose
values are fully known after compile-time constant evaluation.

Current implementation status:

- Implemented: immutable global string constants materialized to string
  literals are emitted as static `blorp_String` objects.
- Implemented: immutable global pointer-storage `List[T]` constants are emitted
  as static `blorp_List` objects when every element is already supported by the
  static-value emitter. This includes `List[String]` literals and lists of
  supported static heap records.
- Implemented: immutable global inline-storage `List[T]` constants are emitted
  as static `blorp_List` objects for primitive literal slots whose lowered
  representation is fixed-width integer-like inline storage, such as
  `List[Int]`.
- Implemented: immutable global `List[Float]` constants are emitted as static
  `blorp_List` objects with `double` inline storage, matching the existing
  boxed-float bit representation used by normal inline list reads and writes.
- Implemented: immutable global `List[Float32]` constants are emitted as static
  `blorp_List` objects with `float` inline storage. CTFE supports `to_float32`
  for scalar constant construction, so sized Float32 list constants can be
  materialized without startup allocation.
- Implemented: immutable global `List[Float16]` constants are emitted as static
  `blorp_List` objects with `_Float16` inline storage. CTFE supports
  `to_float16` for scalar constant construction and rounds through the binary16
  representation before materialization.
- Implemented: immutable global non-generic heap record constants whose fields
  are primitive literals, string literals, or nested supported records are
  emitted as static record objects.
- Implemented: ordinary generic records/structs used with concrete type
  arguments are rewritten to concrete monomorphized layouts before codegen.
  Static record constants over those concrete layouts are emitted when their
  fields are in the supported static-record subset.
- Implemented: ordinary generic unions used with concrete type arguments are
  rewritten to concrete monomorphized type identities before codegen. Their
  concrete payload fields use typed C storage unless the payload crosses an
  explicit runtime-erased boundary, and source generic union templates are
  pruned when only concrete instantiations are needed.
- Implemented: immutable global constants constructed with ordinary concrete
  generic union constructors are emitted as static union objects when every
  payload is already supported by the static-value emitter. This includes
  nested static generic-record payloads.
- Implemented: immutable global tuple constants are emitted as static
  `blorp_Tuple` objects when every erased slot can be represented as a C static
  initializer: pointer slots to supported static values, primitive literal
  slots, floating-point literal slots encoded with the runtime box bit pattern,
  or void slots.
- Implemented: runtime-erased bridge unions such as `RecvAttempt[T]` remain on
  erased payload storage explicitly because their values are constructed from
  runtime `void*` slots. Moving those to typed payload storage requires a
  dedicated unbox-and-release bridge at the runtime boundary.
- Not implemented yet: static emission for inline-struct lists, dicts, sets,
  tensors, erased dynamic-boundary values, tuple slots that require heap boxes
  such as `Int128`, `UInt128`, and stack-struct payloads, and broader nested
  static object graphs beyond the supported string/list/tuple/record/union
  subset.

The compiler can already evaluate many pure global constant initializers at
compile time. For example:

```blorp
TO_PREPEND = ["these", "args"]

PREPEND_STR = TO_PREPEND.join(",")


pure func transform_args(args: List[String]) -> String:
    PREPEND_STR + args
        .join("AHHH")
        .upper()
```

The current C backend correctly avoids recomputing `TO_PREPEND.join(",")` at
startup. It emits both `TO_PREPEND` and `PREPEND_STR` as static runtime objects.
It also emits the initial heap record subset statically, including concrete
generic record instantiations such as `Box[String]` when their fields are
otherwise statically supported. It also emits supported concrete generic union
constants statically when their payload values are statically supported. It
also emits supported tuple constants as static `blorp_Tuple` objects with an
accurate release mask. Most other heap-shaped values such as general `List`,
`Dict`, erased dynamic-boundary unions, tuple slots that require runtime boxes,
and boxed unions are still commonly materialized through startup code in
`__blorp_init_globals()`. Ordinary generic unions now get concrete type
identities such as `Choice__mono_String`, and those concrete layouts use typed
payload fields such as `blorp_String* field0` or `long field0`. Erased payload
storage remains only at explicit dynamic boundaries such as channel receive
attempts.

That is a transitional implementation detail, not the long-term target.

## Current Behavior

Older backend output, and current fallback output for unsupported heap-shaped
constants, may emit code shaped like this:

```c
static blorp_String* __sl_4;
static blorp_String* __blorp_get_sl_4(void) {
    if (!__sl_4) __sl_4 = blorp_string_literal_len("these,args", 10L);
    return __sl_4;
}

static blorp_String* PREPEND_STR;

void __blorp_init_globals(void) {
    PREPEND_STR = __blorp_get_sl_4();
    blorp_make_immortal_constant(PREPEND_STR);
}
```

This has two important properties:

- Good: the user computation has already happened at compile time. The generated
  program does not call `join` to initialize `PREPEND_STR`.
- Not good enough: the runtime still constructs or registers heap-shaped objects
  during startup.

The presence of function calls in `__blorp_init_globals()` does not necessarily
mean the value was computed at runtime. In the example above, the value is
already known as `"these,args"`. The calls are runtime object materialization and
immortalization, not source-level computation.

## Desired Semantics

For global constants, Blorp should aim for:

1. Pure global constant initializers are evaluated by the compiler.
2. User computation needed to produce those values does not run at startup.
3. Values that can be represented as static immutable runtime objects should not
   be heap-allocated at startup.
4. Static constants behave exactly like ordinary immutable Blorp values.
5. Mutating or COW operations must never mutate static constant storage in place.

The important distinction is between an addressable runtime representation and a
heap allocation. Runtime code may need a `blorp_String*`, `blorp_List*`, or
record pointer. That pointer does not imply the object must come from the heap.
It can point at static storage when the value is known and immutable.

## Target C Shape

For a compile-time string constant, the backend now emits a shape close to:

```c
static const char PREPEND_STR_data[] = "these,args";

static const blorp_String PREPEND_STR_object = {
    .header = BLORP_STATIC_IMMORTAL_HEADER,
    .len = 10,
    .capacity = 10,
    .data = (char*)PREPEND_STR_data,
};

static blorp_String* PREPEND_STR = (blorp_String*)&PREPEND_STR_object;
```

The exact field names and casts should follow the real runtime layout. The
shape above is illustrative. The invariant is what matters: the object is a
valid Blorp string value, but it lives in static storage and is never freed.

For supported static constants, startup does not need:

```c
PREPEND_STR = __blorp_get_sl_4();
blorp_make_immortal_constant(PREPEND_STR);
```

because the pointer is already initialized to a valid static object.

## Runtime Requirements

Static constants need an explicit representation in the runtime object model.
Avoid relying on incidental refcount values or sentinel pointer tricks.

The runtime should be able to answer:

- Is this object heap-allocated and owned by ARC?
- Is this object static and immortal?
- Is this object uniquely owned and therefore safe to mutate in place?

Static constants should have these properties:

- Retain is a no-op or otherwise harmless.
- Release is a no-op and must not call destructors or `free`.
- Uniqueness checks return false.
- COW operations allocate a mutable heap copy before writing.
- Leak checking does not count static constants as heap allocations.
- Destructors are not run for static constants at program exit.
- Nested static references are also treated as static or immortal.

This should be represented explicitly in the object header or allocation class,
not inferred from magic refcount values. If an external ABI or runtime invariant
requires a particular sentinel value, name that value and document it next to the
runtime definition.

## Type-Specific Emission

### Primitives

Primitive constants can already be emitted as ordinary C scalar statics when the
backend has enough information:

```c
static long ANSWER = 42L;
```

They do not need `__blorp_init_globals()` except when surrounding code currently
funnels all globals through one initializer for implementation convenience.

### Strings

Strings are the first implemented target for static emission.

The backend should emit:

- Static byte storage for the contents, currently through a generated wrapper
  struct with a flexible-array-compatible prefix.
- A static `blorp_String` object with the correct header, length, capacity, and
  inline data.
- A global pointer or direct global object reference matching the generated C
  conventions.

String operations that might mutate or reserve capacity must treat static
strings as not unique and allocate before mutation.

### Lists

The implemented list subset covers pointer-storage lists where every element is
itself supported by static emission. The backend emits each element as a static
object when needed, then emits a layout-compatible static `blorp_List` wrapper
whose data slots point at those values. This includes `List[String]` literals
and lists of supported heap records.

The subset also covers inline fixed-width primitive literal lists such as
`List[Int]`, plus `List[Float]`, `List[Float32]`, and `List[Float16]`. These
emit a layout-compatible static
`blorp_List` wrapper with `BLORP_LIST_STORAGE_INLINE`, the concrete slot width,
and static slot data using the same bit representation normal inline list writes
use. `List[Float]` uses `double data[]` so runtime `blorp_list_get` copies the
same bytes that `blorp_box_float`/`blorp_unbox_float` expect. `List[Float32]`
uses `float data[]` for the corresponding 32-bit inline representation.
`List[Float16]` uses `_Float16 data[]` for the corresponding 16-bit inline
representation.

List constants can be emitted statically when:

- The length is known.
- The element values can be statically emitted, safely represented as
  integer-like inline primitive literal slots, or represented as supported
  floating-point inline slots.
- The lowered list representation uses pointer storage or supported fixed-width
  primitive inline storage.
- The list container is immutable and static.
- COW operations allocate a mutable heap copy before mutation.

A possible shape:

```c
static void* TO_PREPEND_items[] = {
    (void*)&TO_PREPEND_item_0,
    (void*)&TO_PREPEND_item_1,
};

static const blorp_List TO_PREPEND_object = {
    .header = BLORP_STATIC_IMMORTAL_HEADER,
    .len = 2,
    .capacity = 2,
    .data = TO_PREPEND_items,
    .elem_release = blorp_elem_release_fn,
};
```

The exact layout should follow the runtime list representation. If the runtime
expects mutable capacity or release-function fields, the static representation
must preserve those invariants without permitting in-place mutation.

### Records, Tuples, Structs, and Unions

The first implemented record case is a heap record with no erased fields, where
every field is a primitive literal, a string literal, or another supported
static record. This includes ordinary generic record instantiations after
monomorphization has produced a concrete layout. The emitted object uses the
same C struct type as the runtime heap record, with an immortal header and
statically emitted child objects.

Broader records and boxed unions are good candidates once this subset is stable.
The static object must match the runtime layout exactly and must recursively
reference static or otherwise immortal nested values.

Structs that are represented directly in C value storage may not need heap-like
static object handling.

Tuples currently follow their lowered `blorp_Tuple` representation: a static
object with an immortal header, arity, release mask, and `void*` element slots.
The first supported subset covers pointer slots to other supported static
values, primitive literal slots represented as `(void*)(long)(...)`, and void
slots. Floating-point literal slots are encoded as the exact `void*` bit
patterns expected by `blorp_unbox_float`, `blorp_unbox_float32`, and
`blorp_unbox_float16`. Tuple elements that still require heap boxes, such as
Int128 values, UInt128 values, or stack-struct payloads, remain
runtime-materialized until the backend has a static box representation for those
payloads.

### Generic Data Layout

Static emission should not treat erased generic record fields as the long-term
representation to support.

Supported initial example:

```blorp
record Box[T] { value: T }

BOX: Box[String] = { value = "x" }
```

This now compiles through a concrete `Box[String]` layout rather than by making
the `value: T` field an erased `void*` slot. Erased storage remains acceptable
as a compatibility fallback at explicitly dynamic boundaries, but it is not the
right target representation for ordinary user generic data.

The target is concrete monomorphized layouts:

```c
typedef struct Box__mono_String {
    blorp_Object header;
    blorp_String* value;
} Box__mono_String;

typedef struct Box__mono_Int {
    blorp_Object header;
    long value;
} Box__mono_Int;
```

Policy:

- Monomorphize generic records, structs, and unions at concrete instantiations
  used by runtime code or static constants.
- Generate concrete C type declarations, constructors, destructors, field
  accessors, update helpers, and release policies per instantiated data type.
- Keep erased storage only at explicit dynamic boundaries, such as trait-object
  values, future `Any`-like values, FFI/runtime container shims, and closure or
  scheduler internals where the boundary is intentionally dynamic.
- Represent every erased crossing with explicit IR/layout metadata. Do not infer
  it from a source type variable, generated C spelling, or a record-field name.
- Let static emission consume concrete layouts and release policies. It should
  not rediscover whether `Box[String].value` needs a release by inspecting an
  erased field slot.

Implementation path:

1. Done for records/structs: introduce a concrete data-instantiation identity
   based on the source declaration and concrete type arguments.
2. Done for records/structs: teach monomorphization to collect used data
   instantiations, not only generic function instantiations.
3. Done for records/structs: generate concrete data declarations before
   emission needs C layout strings. Existing record helper generation then
   consumes those concrete declarations.
4. Done for record construction, field access, update, destructor, and
   release-mask use sites that flow through the normal Core monomorphization
   pipeline.
5. Preserve erased storage only through named dynamic-boundary nodes or layout
   facts.
6. Done for ordinary generic unions: produce concrete instantiated type
   identities, replace ordinary payload slots with typed concrete storage where
   the instantiation makes the payload type known, and prune the source generic
   union template from emitted C.
7. Done for ordinary generic unions: emit static values for concrete typed
   union layouts when every payload is supported by the static-value emitter.
   Keep erased payload storage only at explicit dynamic boundaries, and add
   typed bridge support for those boundaries when worthwhile.
8. Next: cover any remaining direct prepared-Core tests that intentionally
   bypass monomorphization.

Required tests for that work:

- `Box[Int]` emits a concrete layout with an unboxed integer field and no managed
  field release.
- Done: `Box[String]` emits a concrete layout with a string pointer field and a
  managed field release.
- Done: a global `Box[String]` constant can be emitted statically.
- Done: a generic union instantiation emits concrete type identities and does
  not emit the source generic union template.
- Done: an ordinary generic union payload has typed concrete instantiated
  storage.
- Done: a global ordinary generic union constant can be emitted statically,
  including a nested generic-record payload.
- Nested generic records use concrete nested layouts.
- An intentionally erased dynamic boundary still emits explicit box/unbox nodes
  and remains visible in the erasure inventory.

### Tensors

Fixed-shape tensors should be considered after strings and lists. They need:

- Static element storage.
- Correct shape, length, and capacity metadata.
- COW behavior that copies before writes.
- Alignment that matches SIMD and runtime expectations.

### Dicts and Sets

Dicts and sets are more delicate and should come later.

Reasons:

- Runtime layout includes hash table metadata.
- Hash and equality behavior may depend on element type.
- Order metadata may need to be preserved.
- Cached hash or growth thresholds may exist.

The first implementation may continue to materialize dicts and sets at startup
while strings, lists, records, tuples, unions, and tensors move to static
emission. That is acceptable as long as the limitation is explicit and covered
by codegen audit tests.

## Pipeline Direction

The clean architecture is:

1. Typecheck globals normally.
2. Evaluate immutable pure global constants through CTFE.
3. Preserve a typed evaluated value graph for constants that can be emitted
   statically.
4. Lower runtime code normally.
5. In codegen, emit static data for supported evaluated value graphs.
6. Fall back to startup materialization only for unsupported static shapes.

Avoid making static emission depend on source names, string prefixes, formatter
shape, or other heuristics. The compiler should carry explicit metadata such as:

- This global was evaluated at compile time.
- This evaluated value is safe to emit as static storage.
- This value still needs runtime materialization.
- This value is runtime-initialized and not a compile-time constant.

The emitter should not need to rediscover these facts by inspecting generated C
fragments.

## Relationship to `__blorp_init_globals()`

`__blorp_init_globals()` may still be useful for:

- Mutable globals, if the language permits or retains them internally.
- Runtime-initialized globals that cannot be CTFE-evaluated.
- Constants whose value is known but whose static emission is not implemented
  yet.
- Runtime subsystem setup that is not source-level constant initialization.

But fully static-supported compile-time constants should not require startup
allocation or registration in `__blorp_init_globals()`.

For the example:

```blorp
PREPEND_STR = TO_PREPEND.join(",")
```

the desired generated C should show:

- The value `"these,args"` in static storage.
- `PREPEND_STR` pointing at a valid static `blorp_String`.
- No startup call to `join`.
- No startup allocation for `PREPEND_STR`.
- No startup immortalization call for `PREPEND_STR`.

## Correctness Invariants

Static constants must preserve Blorp value semantics:

- Reads observe the same value as runtime materialization would have produced.
- Equality and hashing produce the same results.
- Pattern matching behaves the same.
- Passing the value through pure and impure functions behaves the same, except
  allocation counts may improve.
- No user-visible pointer identity is introduced.
- Static values are thread-safe by construction.
- Static values cannot be mutated in place, even through COW fast paths.
- ARC operations are correct for mixed graphs of static and heap values.
- Leak checking remains meaningful and does not report static constants as
  leaked heap objects.

The most important COW rule:

> A static constant is never unique.

Any operation that wants unique mutable storage must allocate a heap copy before
writing.

## Testing Plan

Add tests in layers.

### Codegen Audit

For a string constant:

```blorp
TO_PREPEND = ["these", "args"]
PREPEND_STR = TO_PREPEND.join(",")
```

Audit generated C for:

- Contains the literal `"these,args"`.
- Does not call `join` from global initialization.
- Does not assign `PREPEND_STR` inside `__blorp_init_globals()` once static
  string emission is implemented.
- Does not call `blorp_make_immortal_constant(PREPEND_STR)` once static string
  emission is implemented.
- Emits a static runtime string object or equivalent named helper.

For list constants:

- The generated C contains static element storage.
- The generated C does not allocate the list in `__blorp_init_globals()`.
- Nested string elements are statically referenced.

For COW:

- Updating a list or string derived from a static constant allocates a mutable
  copy and leaves the original unchanged.

### Runtime Tests

Runtime behavior should prove:

- Constants read correctly.
- Repeated reads are stable.
- Passing static constants to existing std functions works.
- Mutating derived values does not mutate the original constant.
- Concurrent reads are safe.

### Leak Tests

Leak checks should prove:

- Static constants do not appear as heap leaks.
- Copy-on-write from static constants releases heap copies correctly.
- Mixed static and heap graphs release correctly.

### Sanitizers

Sanitizer runs should cover:

- Release of static constants.
- COW mutation paths.
- Nested static values.
- Program exit cleanup.

## Suggested Implementation Slices

1. Add explicit runtime support for static immortal ARC objects.
2. Make retain, release, destructor dispatch, leak tracking, and uniqueness
   checks understand static objects.
3. Emit static strings for CTFE-evaluated global constants. Done for immutable
   global string literal initializers.
4. Add codegen audit coverage for the `PREPEND_STR` example. Done in
   `global_constant_static_string.brp`.
5. Emit static lists of statically-emittable values. Done for pointer-storage
   lists whose elements are supported static values.
6. Add COW regression coverage for static strings and lists.
7. Emit static non-generic records. Done for primitive, string, and nested
   supported-record fields.
8. Implement concrete monomorphized layouts for ordinary generic
   records/structs. Initial record/struct support is in place.
9. Emit static records and boxed unions through concrete data layouts. Initial
   static generic-record support is in place. Ordinary generic unions now have
   concrete type identities, typed ordinary payload storage, and static emission
   for payloads in the supported static-value subset.
10. Emit static tuples through the lowered tuple layout. Done for pointer,
    primitive-literal, and void slots whose nested values are supported static
    constants.
11. Emit static tensors after confirming alignment and COW requirements.
12. Evaluate whether dicts and sets should be statically emitted or kept as a
   startup-materialized fallback longer term.

Each slice should be independently correct. Do not introduce a static emission
path that works only because current std functions happen not to mutate a value.
Runtime uniqueness and COW behavior must make static constants safe globally.

## Non-Goals

This design does not require:

- Eliminating `__blorp_init_globals()` entirely.
- Statically emitting every possible CTFE value in the first implementation.
- Supporting impure global initializers.
- Changing source-level value semantics.
- Exposing static object identity to users.
- Preserving old `compile_time:` block syntax.

## Open Questions

- What exact runtime header field should represent static immortal storage?
- Should static object headers be `const`, or do existing runtime APIs require
  mutable header fields?
- Should static string data be `const char[]`, or should COW enforcement rely on
  the object header while the data pointer remains mutable in type?
- How should static constants interact with profiling and memory statistics?
- Should static dicts/sets precompute hash metadata or use a compact readonly
  lookup representation?
- What is the smallest Core/API shape that makes generic record, struct, and
  union instantiations explicit without duplicating the existing function
  monomorphization machinery?
- How much of `__blorp_init_globals()` can be mechanically pruned once common
  constants use static emission?

These questions should be resolved explicitly in runtime/codegen types and
tests, not with ad hoc generated C patterns.
