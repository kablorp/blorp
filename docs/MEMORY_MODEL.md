# blorp Memory Model

## The Big Idea

blorp aims to minimize the mental load of memory management while maximizing under-the-hood performance. Three principles define the model:

- **Immutability is the default.** Bindings are immutable unless declared with `var`.
- **`var` means rebinding, not mutation.** You point a name at a new value — the old value is semantically untouched.
- **COW containers mutate when they can.** Under the hood, lists, strings,
  tensors, dicts, sets, and other runtime-owned buffers can skip a copy when
  uniquely owned. Plain record update is not a COW path today; it constructs a
  new record.

That's it. The rest of this document is details.

Compiler contributors should also read `docs/OWNERSHIP_MODEL.md`. That document
is the lower-level ABI contract for Perceus, call ownership, and COW. This file
describes the user-facing behavior.

---

## Values and Names

### Immutable bindings are the default

```blorp
x: Int = 5
list: List[Int] = [1, 2, 3]
```

These names cannot be rebound. `x` is `5` forever (within its scope). `list` is `[1, 2, 3]` forever.

### `var` allows rebinding

```blorp
var count: Int = 0
count = count + 1       -- count now refers to the value 1

var items: List[Int] = [1, 2, 3]
items = items.append(4) -- items now refers to [1, 2, 3, 4]
```

`var` does not make the *value* mutable. It makes the *name* mutable — you can point it at a different value. The old value still exists (briefly) until nothing references it.

Redeclaring a name that already exists in the same scope is a compile error — use `var` if you need to rebind.

---

## How Each Type Works

### Primitives (Int, Float, Bool, Char)

Primitives are values, not references. Rebinding is just overwriting a local variable on the stack.

```blorp
var x: Int = 5
x = x + 1          -- overwrites a stack slot, no heap involved
```

No copying, no allocation. 

### Option Representation

`Option[T]` is the user-facing way to represent absence. There is no
language-level null: pattern matching and `Some`/`None` semantics are the same
regardless of the payload type. The compiler chooses the internal layout from
the payload type:

| Payload kind | Internal layout |
| --- | --- |
| `Int`, sized integers through `UInt64`, `Float`, `Bool`, `Char`, `Float32`, `Float16` | Runtime stack struct `{tag, value}` |
| `Int128`, `UInt128`, range types (`..#N`), enums, and `struct` value records | Generated per-type stack struct `{tag, value}` |
| Managed non-null payloads such as `String`, `List[T]`, `Dict[K,V]`, heap `record`, non-enum `union`, tuples, and functions | Nullable managed pointer internally: payload pointer for `Some`, `NULL` for `None` |
| Nested options, `Ptr`, unresolved generic payloads, and unsupported payloads | Boxed `Option` union |

Direct stack-option values do not have ARC ownership of their own. Monomorphic
`List[Option[T]]` values whose payload has a stack-option layout store those
stack structs inline in list slots, so list construction, indexing, and
iteration do not allocate an `Option` box. Other erased storage sites, such as
tuples and closure ABI slots, may still box stack options into ARC objects as a
compatibility fallback. That fallback is an implementation detail of erased
storage boundaries, not part of the source-language contract.

The nullable-pointer layout is an implementation detail. It is only used for
managed payloads where `NULL` cannot be a valid source value. `Option[Ptr]`
stays boxed so `Some(ptr)` remains distinguishable from `None`, even if `ptr`
is a null foreign pointer.

Runtime builtins follow the same ABI policy as generated code: a builtin whose
source type is `Option[String]`, `Option[List[T]]`, or `Option[Tensor]` returns
the managed payload pointer for `Some` and `NULL` for `None`, not a heap
`Option` wrapper.

### Records

Records are heap-allocated. Update syntax constructs a new record:

```blorp
record Point { x: Int, y: Int }

p: Point = { x = 1, y = 2 }
q: Point = { p | x = 10 }      -- allocates a new Point, copies all fields
-- p is still { x = 1, y = 2 }
-- q is { x = 10, y = 2 }
```

All record updates currently materialize a fresh record object, even when you
rebind the same variable. Unchanged managed fields are retained as needed, and
the previous record is released by normal ownership cleanup. Collection COW is a
separate runtime optimization; do not rely on in-place record update for
performance.

```blorp
var state: GameState = { score = 0, lives = 3, level = 1 }
state = { state | score = state.score + 10 }   -- constructs a new GameState
```

Aliasing remains safe because update syntax always produces a distinct record:

```blorp
original: Point = { x = 1, y = 2 }
var working: Point = original
working = { working | x = 99 }         -- constructs a new Point
-- original is still { x = 1, y = 2 }
```

### Lists

List operations return new lists (semantically). Under the hood, they use **copy-on-write**:

```blorp
var items: List[Int] = [1, 2, 3]
items = items.append(4)         -- mutates in place (items is the only reference)
```

But if the list is shared:

```blorp
original: List[Int] = [1, 2, 3]
copy: List[Int] = original      -- both point to the same data
var working: List[Int] = copy
working = working.append(4)     -- copies first, then appends to the copy
-- original is still [1, 2, 3]
```

Operations with COW: `append`, `set`, `insert`, `remove`, `concat`.

Bounds-checked operations return `Option[List[T]]`:

```blorp
match items.set(0, 99):
    Some(updated): updated      -- new list (or same list, mutated in place)
    None: items                 -- index was out of bounds
```

### Tensors and Fixed-Size Vectors

Fixed-size vector and tensor values are runtime containers. `set_index` follows
the collection COW protocol and returns an `Option`:

```blorp
v: Int[#3] = {10, 20, 30}
match v.set_index(0, 99):
    Some(updated): updated      -- [99, 20, 30]
    None: v                     -- shouldn't happen, 0 < 3
```

Subscript read is direct and bounds-checked at compile time:

```blorp
x: Int = v[0]                  -- direct memory access, no Option
```

### Closures

Closures capture values **by snapshot**. At the moment the closure is created, it copies the current value of every variable it references:

```blorp
x: Int = 10
f: (Int) -> Int = func(y): x + y   -- captures x=10
-- even if x could somehow change, f still sees 10
```

The type checker enforces that closures **cannot capture `var` bindings**. This prevents a whole class of bugs:

```blorp
var count: Int = 0
-- ERROR: f = func(): count + 1
-- Cannot capture mutable variable 'count'
```

If you need stateful closures, thread state explicitly through function parameters.

---

## The Rebinding Pattern

The core pattern in blorp is: **compute a new value, rebind the name**.

### Building up a list

```blorp
var result: List[Int] = []
for item in source:
    result = result.append(transform(item))
result
```

Because `result` is the only reference, the runtime mutates in place — this is O(1) amortized per append, just like a mutable `ArrayList`.

### Updating a record in a loop

```blorp
var state: GameState = initial_state
for event in events:
    state = { state | score = state.score + event.points }
state
```

Each iteration allocates a new `GameState`. This is the cost of record immutability — but records are typically small, so the copy is cheap.
For hot loops over large state, keep the changing fields in local variables or a
collection designed for COW updates, then build the record at the boundary.

### Accumulating with fold

```blorp
total: Int = numbers.fold_left(0, func(acc, n): acc + n)
```

`fold_left` threads the accumulator through the function. No mutation needed.

---

## Patterns to Avoid

### 1. Forgetting to rebind after append

```blorp
-- BAD: append returns a new list, but we ignore it
var items: List[Int] = [1, 2, 3]
items.append(4)         -- return value is discarded!
print(items.length())   -- still 3
```

**Fix:** Always rebind:

```blorp
-- GOOD
var items: List[Int] = [1, 2, 3]
items = items.append(4)
print(items.length())   -- 4
```

This is the most common mistake. `append` does not modify `items` — it returns a new list.

### 2. Aliasing before a mutation sequence

```blorp
-- SAFE: aliasing + mutation works correctly via COW
var items: List[Int] = [1, 2, 3]
backup: List[Int] = items           -- retain bumps refcount
items = items.append(4)             -- COW detects sharing, copies
-- backup is still [1, 2, 3], items is [1, 2, 3, 4]
```

The compiler emits `blorp_retain` when a managed alias creates another logical owner, such as `let backup = items` or a field alias. This bumps the refcount so that mutation operations correctly detect sharing and copy before writing. Direct user-call ownership is inferred from function bodies: read-only parameters borrow, while passthrough or mutating parameters consume the caller's owner.

### 3. Trying to mutate a closure's captured state

```blorp
-- WON'T COMPILE: closures can't capture var bindings
var total: Int = 0
adder = func(x): total += x    -- ERROR
```

**Fix:** Use explicit state threading:

```blorp
-- GOOD: fold threads state through the accumulator
total: Int = numbers.fold_left(0, func(acc, n): acc + n)
```

### 4. Chained record updates in a hot loop

```blorp
-- CLEAR, but allocates a new Point each iteration today
var p: Point = { x = 0, y = 0 }
for i in range(0, 1000000):
    p = { p | x = p.x + 1 }
```

If the record update is on a hot path, use separate local variables or a more
appropriate data structure:

```blorp
-- no record allocation in the loop
var px: Int = 0
var py: Int = 0
for i in range(0, 1000000):
    px = px + 1
p: Point = { x = px, y = py }  -- one allocation at the end
```

### 5. Using set_index without handling the Option

```blorp
-- BAD: ignoring the return value
v: Int[#3] = {1, 2, 3}
v.set_index(0, 99)             -- returns Option, discarded
```

**Fix:** Match on the result:

```blorp
-- GOOD
v: Int[#3] = {1, 2, 3}
match v.set_index(0, 99):
    Some(updated): use(updated)
    None: handle_error()
```

---

## Under the Hood

This section is for contributors working on the compiler and runtime.

### What the compiler actually generates

blorp compiles to C. Here's what the generated code looks like for common patterns:

**Variable rebinding:**
```c
// var x: Int = 5
long x = 5;
// x = x + 1
x = x + 1;
```

**Variable shadowing:**
```c
// x: Int = 5
const long x = 5;
// x: Int = x + 1
const long x__1 = x + 1;   // mangled name, RHS uses old x
```

**Record update:**
```c
// q = { p | x = 10 }
({
    Point* __upd_0 = p;
    Point* q = Point_make(10, __upd_0->y);
    q;
})
```

`CRecordUpdate` is desugared before emission into a temporary binding for the
base plus a normal record constructor call. Generated C may include retains and
drops around managed unchanged fields, but it does not use a record-specific COW
branch.

**Record alias (retain):**
```c
// copy: Point = original
Point* copy = original;
blorp_retain(copy);               // bump refcount for the new owner
```

**List append:**
```c
// items = items.append(42)
items = blorp_list_append(items, (void*)(long)42);
```

The `blorp_list_append` function handles COW internally.

### The refcount system

Every heap object starts with a `blorp_Object` header containing an atomic
refcount plus compact runtime metadata:

```c
typedef struct {
    _Atomic long refcount;
    uint32_t alloc_class;
    uint32_t destructor_id;
} blorp_Object;
```

Exact allocation sizes, memory-stats epochs, leak-report type tags, and
live-object links are cold metadata. They are kept in a side table only when
memory stats or `BLORP_LEAK_CHECK` are active, not in every object header.
Destructor functions are stored once in a runtime registry; each object stores
only a compact destructor id.

| Function | Effect |
|----------|--------|
| `blorp_alloc(size)` | Allocate from a small-object pool or `malloc`, then initialize the object header and refcount |
| `blorp_retain(obj)` | Atomic increment |
| `blorp_release(obj)` | Atomic decrement; run the destructor and free or recycle storage at 0 |
| `blorp_is_unique(obj)` | `true` if refcount == 1 |

**Retain/release status:** The Core IR pipeline inserts Perceus-style
`CDup`/`CDrop` nodes during the `core_perceus` pass, which lower to
`blorp_retain` / `blorp_release` calls in emitted C. Objects are freed when
their refcount drops to zero — there is no garbage collector and no arena.

- Aliasing a COW type bumps the refcount, so mutation operations can detect sharing and copy only when necessary.
- Read-only function parameters are **not** retained on entry. The caller's live reference keeps the object alive for the duration of a synchronous call, and the callee reads without touching the refcount.
- Runtime mutators that participate in COW (e.g. `blorp_list_append`) consume the receiver owner and drop the old reference themselves when they copy, so the caller's updated binding receives a fresh owning pointer.

The compiler-facing definitions of `Borrow`, `Retain`, `Consume`,
`CowConsume`, `Transfer`, and result ownership modes live in
`docs/OWNERSHIP_MODEL.md`.

**Current Perceus and reuse scope.** The Perceus pass inserts `CDup` / `CDrop`
for managed bindings in linear bodies and supported branch forms, retains alias
sources so COW containers can observe sharing, honors known intrinsic / builtin
ownership contracts, infers conservative direct user-call contracts from
function bodies, treats direct foreign calls as borrowed at the Perceus layer,
and keeps concurrent binding lifetimes conservative.

Closure and task lowering make captures Core-visible before emission. The
emitter/runtime closure ABI records retained capture slots in an
`env_release_mask`, so closure destruction releases captured RC values. A
closure or task body that directly returns a captured pointer-class value retains
it before returning, so the returned owner does not depend on the closure
environment staying alive.

The Blorp reuse stage runs after Perceus and consumes proven post-drop facts. It
rewrites narrow, compatible collection allocations through explicit runtime reuse
boundaries such as `list_reuse_alloc`, `set_reuse_alloc`, and `dict_reuse_alloc`,
plus explicit list producer handoff paths. Those boundaries clear/release old
contents, preserve compatible collection metadata, and only reuse storage when
the runtime owner is unique.

Some ownership edges are still intentionally conservative: closure call
arguments, loop / try / detach liveness, and structured-concurrency task-result
handoff use explicit boundaries rather than a fully general call ABI model.

### Copy-on-Write protocol

COW mutating runtime functions follow this pattern:

```c
blorp_List* blorp_list_append(blorp_List* list, void* element) {
    if (!blorp_is_unique(list)) {
        // Shared: copy first, release our reference to old
        blorp_List* copy = blorp_list_copy_with_capacity(list, ...);
        blorp_release(list);
        list = copy;
    } else if (list->len >= list->capacity) {
        // Unique but full: reallocate
        blorp_List* bigger = blorp_alloc(...);
        memcpy(bigger->data, list->data, ...);
        blorp_release(list);
        list = bigger;
    }
    // Now unique with capacity: mutate in place
    list->data[list->len++] = element;
    return list;
}
```

The caller **must** use the return value, not the original pointer.

### What's heap-allocated vs. stack

| Stack (value types) | Heap (reference types) |
|---------------------|----------------------|
| `Int`, `Float`, `Bool`, `Char` | `String` |
| `struct` values | Heap `record` values |
| Tuple values when scalar-replaced or represented as local value slots | `List[T]` |
| | tensors and fixed-size vectors (`T[#N]`, runtime tensor/vector container) |
| | `Dict[K, V]` |
| | Closures |
| | Union type constructors with payloads |

Tuples are source-level values, not always heap objects. Non-escaping local
tuples and some narrow tuple-return call sites can be scalar-replaced by the
Core tuple SROA pass. Escaping tuples use the lowered representation required by
their storage and call boundary.

### Closure capture mechanism

Closures with captures allocate a `blorp_Closure` with an inline `void**`
environment and copy captured values into it. Primitive captures are copied into
slots; managed captures are retained, and the generated closure records which
environment slots must be released:

```c
// func(y): prefix + y  where prefix is a captured String
blorp_Closure* __cl = blorp_closure_new_inline((void*)lambda_0, 1);
((void**)__cl->env)[0] = blorp_retain(prefix);
__cl->env_release_mask = 1UL;
```

Zero-capture closures are emitted as immortal static closure objects instead of
allocating a runtime environment.

Inside the lambda, captured values are unpacked with a `_cap_` prefix:

```c
blorp_String* lambda_0(void* __env_raw, blorp_String* y) {
    void** __e = (void**)__env_raw;
    blorp_String* _cap_prefix = (blorp_String*)__e[0];
    return blorp_string_concat(_cap_prefix, y);
}
```

Pointer-typed captures (strings, lists, records) copy the pointer, not the data. This is safe because values are semantically immutable — the captured pointer will always point to the same logical value.

---

## Summary

| Concept | User model | Reality |
|---------|-----------|---------|
| `var x = x + 1` | New value, same name | Overwrites stack slot |
| `list.append(4)` | Returns a new list | Mutates in place if unique, copies if shared |
| `{ rec \| field = v }` | New record with one field changed | Constructs a fresh record today |
| `v.set_index(i, x)` | `Option` of a new vector | Mutates in place if unique, copies if shared |
| Closure capture | Snapshot of values at creation time | Static closure for zero captures; inline env with retained managed captures otherwise |
| Memory management | Automatic, don't think about it | Perceus-style refcounting; objects freed at refcount 0 |

The gap between "user model" and "reality" is the implementation detail. Write your code against the user model. The runtime handles the rest.
