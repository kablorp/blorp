# Static Emission for Compile-Time Constants

## Status

Blorp evaluates pure immutable global initializers during compilation. The
backend then chooses between three representations for the evaluated value:

1. Inline scalar C data when the value has no runtime ownership.
2. Static runtime storage for recursively static, string-free object graphs.
3. Ordinary ARC-managed startup values for graphs that contain strings or
   otherwise need runtime construction.

Strings are never immortal. A string produced by generated code is an ordinary
ARC allocation and participates in profiling, leak checking, retain/release,
and copy-on-write exactly like any other string.

## Why Strings Are Mortal

The previous backend represented string literals and string-containing global
constants with an immortal refcount. That made every executed literal a
process-lifetime allocation and removed it from allocation tracking. It also
required special cases in ownership analysis, global initialization, COW, and
tests.

That representation violated the normal value lifecycle and made allocation
profiles misleading. The current contract is simpler:

- `blorp_string_create` and `blorp_string_create_len` return owned strings with
  refcount 1.
- Core string literal expressions produce owned values.
- Perceus inserts the same drops and retains used for other managed values.
- Literal matches and comparisons that retain a literal operand through Core
  call `blorp_string_compare_bytes`, avoiding a temporary string allocation.
- Runtime helpers returning constant text return a new owned string.
- Boxed `Result.Err[String]` values set their release mask and own the string.

There is no separate literal-string ownership class.

## Global Constant Policy

### Strings and String-Containing Graphs

String globals and globals that contain strings are ordinary managed roots.
This includes lists, records, tuples, unions, stack Results, and dictionaries.
They are constructed once in `__blorp_init_globals()` and released in reverse
initialization order by the runtime's single generated-global cleanup callback.

Representative generated C:

```c
static LabelBox* LABEL_BOX;

static void __blorp_drop_globals(void) {
    blorp_release(LABEL_BOX);
}

void __blorp_init_globals(void) {
    LABEL_BOX = LabelBox_make(blorp_string_create("ready"));
    blorp_register_global_cleanup(__blorp_drop_globals);
}
```

Reads of a managed global are borrowed. Ownership analysis retains the value
only when an expression consumes, stores, or returns it.

### Static String-Free Constants

Static storage remains valid for values that can be represented without a
runtime-owned child. Current examples include:

- C scalar globals.
- Fixed-width inline lists of integer and floating-point values.
- Pointer lists whose elements are recursively static and string-free.
- String-free records, tuples, concrete unions, and stack Results supported by
  the static-value emitter.
- Nullary union constructor singletons and static closure descriptors.

These objects use the runtime's named immortal refcount because they are real
static C objects, not heap allocations. Retain/release are no-ops and uniqueness
checks are false. The distinction is based on the explicit lowered value shape,
not source names or generated-C text.

Static emission must fail closed for an unsupported child. In particular, a
record or tuple that contains a string must use normal runtime construction for
the complete owned graph.

## Correctness Invariants

- Every heap-allocated string has a finite ARC lifecycle and remains visible to
  profiling and leak checking.
- Every generated literal expression has a clear owner or an inserted drop.
- A global root owns its runtime-constructed value until shutdown.
- Global cleanup runs in reverse initialization order.
- A value borrowed from a global is retained before escaping that borrow.
- Static objects never contain pointers to mortal objects.
- Mutable-global reassignment releases the previous owned value.
- Literal comparison paths represented explicitly in Core do not allocate
  merely to obtain the comparison operand.
- No pass infers global identity from a string prefix or source spelling.

## Pipeline Placement

The relevant late pipeline order is:

1. CTFE materializes compile-time global values.
2. Core lowering preserves mutability, constness, visibility, and gives each
   global declaration a canonical Core identity.
3. DCE prunes unreachable declarations.
4. Dictionary literals are lowered to explicit boxed construction so entry
   ownership is visible to Perceus.
5. Perceus resolves unique global references with lexical-shadow awareness and
   applies ordinary managed-value ownership, including borrowed global reads.
6. The backend emits static string-free values or runtime initialization and
   shutdown cleanup.

## Testing

Coverage is split by responsibility:

- Core-lowering tests cover global mutability, constness, visibility, and
  declaration identity.
- Perceus tests cover literal ownership, managed values borrowed from globals,
  mutable reassignment, and same-named local bindings.
- Emitter tests cover mortal literal helpers, allocation-free literal
  comparisons, global initialization, and reverse cleanup.
- Generated-C audits cover records, lists, tuples, Results, concrete generic
  data, dictionaries, and CTFE-produced graphs.
- Runtime sanitizer and leak tests repeatedly create literals and copy managed
  global strings into aggregate values, then require balanced allocations and
  releases.

Any new static-value shape must add generated-C and runtime ownership coverage.
Static emission is an optimization; unsupported values must remain correct via
normal ARC-managed initialization.
