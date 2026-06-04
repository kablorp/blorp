# blorp Language Guide

A comprehensive reference for the blorp programming language.

---

## 1. Quick Start

### Hello World

```blorp
func main(args: List[String]):
    print("Hello, world!")
```

Every runnable program needs a `main` function in the root source file being compiled or run. The return type can be `Int` (exit code) or omitted/`Void` (implicit exit 0). If `-> Int` is written, the body must end with an `Int` expression. `args` contains `argv` including the program name at index 0. Imported modules may also export functions named `main`; those imports are ordinary functions and do not become the program entrypoint.

```blorp
-- same function with explicit status code 
func main(args: List[String]) -> Int:
    print("Hello!")
    0
```

### Compile and Run

```bash
# Build the compiler
make

# Compile and run a program
./blorp run hello.brp

# Pass CLI arguments
./blorp run program.brp -- arg1 arg2 arg3

# Type check only (no codegen)
./blorp check program.brp
./blorp check src/              # Recursively checks .brp files

# Show AST
./blorp compile --ast program.brp

# Run tests
./blorp test tests/test_blorp/
./blorp test tests/test_blorp/collections/test_dict.brp
```

### A More Complete Example



```blorp
pure func process(items: List[Int]) -> List[Int]:
    items
        .filter(func(x): x > 0)
        .map(func(x): x * 2)

func main(args: List[String]):
    data: List[Int] = [3, -1, 4, -2, 5]
    result: List[Int] = process(data)
    print(to_string(result))
```

No imports needed for entities included in the prelude, which 
includes List, Option, String, Dict, Set, Result -- and their "methods"! See "Method Call Syntax" below.

---

## 2. Core Syntax

### Functions

```blorp
-- Impure function (can do I/O)
func greet(name: String) -> Void:
    print("Hello, ${name}!")

-- Pure function (no side effects)
pure func square(x: Int) -> Int:
    x * x

-- Generic function
func identity[T](x: T) -> T:
    x

-- Trait-bounded generic
func max_val[T: Orderable](a: T, b: T) -> T:
    match a > b:
        True: a
        False: b

-- Tail-recursive optimization
@tail_recursive
func factorial(n: Int, acc: Int) -> Int:
    if n <= 1:
        acc
    else:
        factorial(n - 1, n * acc)
```

- `func` declares an impure function (can do I/O, call impure functions)
- `pure func` declares a pure function (no side effects)
- Return type follows `->`. Body is indented; last expression is the return value
- `@tail_recursive` verifies all recursive calls are in tail position. The Core pipeline lowers unmanaged scalar self-recursion to explicit loops, and lowers common list-consumer patterns like `[x, ...rest]` into cursor loops instead of allocating a tail list on every step
- `builtin` as a function body indicates a compiler/runtime-provided implementation; `builtin("c_name")` binds std/runtime wrappers to a named C helper

### Lambdas (Anonymous Functions)

The canonical lambda syntax uses the `func` keyword. This avoids ambiguity with
tuple syntax `(a, b)` and keeps anonymous functions visually aligned with named
functions. Pure lambdas should use `pure func`.

```blorp
inc: (Int) -> Int = func(x: Int): x + 1                -- Explicit type
inc2: (Int) -> Int = func(x): x + 1                    -- Type inferred from context
add: (Int, Int) -> Int = func(a, b): a + b             -- Multi-param, types inferred
add2: (Int, Int) -> Int = func(a: Int, b: Int) -> Int: a + b
double: pure (Int) -> Int = pure func(x: Int): x * 2   -- Pure lambda
hello: () -> Void = func(): print("hello")             -- Zero-param lambda
```

Lambda parameter types are inferred from the expected function type at call sites:

```blorp
numbers: List[Int] = [1, 2, 3]
doubled: List[Int] = numbers.map(func(x): x * 2)  -- x inferred as Int
```

### Variables

```blorp
PI: Float = 3.14159265358979
MAX_SIZE: Int = 1024

func get_pair() -> (Int, String):
    (1, "hello")

func some_impure_call() -> Int:
    1

func variable_examples() -> Int:
    -- Immutable binding (default)
    x: Int = 42
    name: String = "Alice"
    y = 100                 -- Type inferred as Int

    -- Mutable variable
    var count: Int = 0
    count = count + 1

    -- Tuple destructuring
    (a, b) = (1, "hello")
    (_, second) = get_pair()

    -- Discarding a value
    _ = some_impure_call()
    0
```

Top-level variable initializers are for data that can be set up without
running user code before `main`. They may use literals, records, structs,
tuples, collections, arithmetic, and union constructors, but they cannot call
functions or methods, use closure calls, or use subscripts that lower to runtime
helper calls. Move runtime work into `main` or into a function called by `main`.

### Control Flow

```blorp
-- If/else (expression — both branches required when used as a value)
result: String = if x > 0:
    "positive"
else:
    "non-positive"

-- If without else (statement — else branch is optional)
if should_log:
    print("logged")

-- Else-if chains
if x > 100:
    "huge"
else if x > 10:
    "medium"
else if x > 0:
    "small"
else:
    "non-positive"

-- While loop
var i: Int = 0
while i < 10:
    print(to_string(i))
    i = i + 1

-- For-in loop (Lists, Vectors, Channels)
for item in my_list:
    print(to_string(item))

-- For-range loop (exclusive end)
for i in 0..10:          -- iterates 0, 1, 2, ..., 9
    print(to_string(i))

for i in start..end:     -- variable bounds work too
    total = total + i

-- For-in with accumulator
func sum_list(nums: List[Int]) -> Int:
    var total: Int = 0
    for n in nums:
        total = total + n
    total

-- break and continue
for i in 0..100:
    if i == 5:
        break               -- exits the loop early
    if i % 2 == 0:
        continue             -- skips to next iteration
    total = total + i

-- void (no-op placeholder for empty branches)
match value:
    Important(x): handle(x)
    Ignored: void

-- Pattern matching (primary control flow)
match value:
    Some(x): x
    None: 0
```

Notes on loops — `while` and `for` loops return `Void`, and values produced
inside the loop body are discarded after evaluation. `break` and `continue` work
in both `for` and `while` loops. In nested loops, `break` only exits the
innermost loop. Range `..` is exclusive: `0..5` gives `0, 1, 2, 3, 4`.
Backwards ranges iterate down and still exclude the end, so `5..3` gives `5, 4`.
Empty ranges (`5..5`) iterate zero times.

Range expressions are first-class `Range` values with `start` and `end` fields:

```blorp
r: Range = 0..10
r.start == 0 and r.end == 10
r.length() == 10
r.contains(4) == True
r.to_list() == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

for i in r:
    print(to_string(i))
```

### Strings

```blorp
greeting: String = "Hello, world!"
char_val: Char = 'a'

-- String interpolation uses ${expr}
-- Any expression is auto-converted to String (no to_string() needed)
name: String = "Alice"
age: Int = 30
info: String = "Name: ${name}, Age: ${age}"
calc: String = "Sum: ${1 + 2 + 3}"
list: String = "Items: ${[1, 2, 3]}"

-- Literal braces work without escaping
json: String = "{\"key\": \"value\"}"

-- Escape sequences: \n \t \\ \" \' \0 \r \u{XXXX}
escaped: String = "line1\nline2\ttabbed"
unicode: String = "Hello \u{1F600}"   -- Unicode escape (1-6 hex digits)
```

Capacity-aware construction uses the normal `String` type. Capacity is a performance hint, not observable behavior.

```blorp
import:
    string: string

var row: String = string(80)
row = row.append_char('#')
row = row.append_str(" done")
```

### Multiline Strings

Multiline strings use aligned `|` markers. The content after each marker is part
of the string, and the markers themselves are stripped. Interpolation works the
same way as in quoted strings:

```blorp
html: String =
    |<html>
    |  <body>
    |    <h1>Hello</h1>
    |  </body>
    |</html>

name: String = "world"
msg: String =
    |Dear ${name},
    |Welcome to blorp!
```

Use `||` when a multiline string line should start with a literal pipe:

```blorp
text: String =
    || starts with a pipe
```

### Raw Strings

Raw strings (`raw"..."`) have no escape processing and no interpolation. Backslashes are literal:

```blorp
-- Useful for regex patterns, file paths, etc.
pattern: String = raw"\d+\.\d+"
path: String = raw"C:\Users\name\Documents"
```

Raw multiline strings use `raw` followed by an aligned pipe block:

```blorp
pattern: String = raw
    |\d+\.\d+
    |${not_interpolated}
```

### Comments

```blorp
-- Single line comment
-- blorp only has single-line comments
-- Use multiple lines like this
```

### Method Call Syntax (UFCS)

Any function can be called as a method using dot notation. The dot operator desugars `x.f(args)` to `f(x, args)` — this is called Uniform Function Call Syntax (UFCS):

```blorp
import:
    list: append, filter, map, sort_by
    
record Person { name: String }

func ufcs_examples() -> List[String]:
    items: List[Int] = [1, 2, 3]

-- These are equivalent:
    updated1: List[Int] = append(items, 4)  -- Bare function call needs import
    updated2: List[Int] = items.append(4)   -- Method call works via UFCS

-- Chaining multiple operations (reads left-to-right)
    result: List[String] = items
        .filter(func(x): x > 0)
        .map(func(x): x * 2)
        .sort_by(func(x): x)
        .map(func(x): to_string(x))

-- A more-indented line starting with "." continues the chain.
-- The formatter uses this shape for longer UFCS chains.

-- Without UFCS chaining (reads inside-out)
    result2: List[String] = map(
        sort_by(
            map(filter(items, func(x): x > 0), func(x): x * 2),
            func(x): x
        ),
        func(x): to_string(x)
    )

-- Works with any function where the first arg matches
    words: List[String] = "hello world".split(" ")
    len: Int = "hello".length()
    my_option: Option[Int] = Some(1)
    fallback: Int = my_option.get_or(0)
    mapped: Option[Int] = my_option.map(func(x): x * 2)

-- Field access (records, tuples) is NOT desugared — has priority
    person: Person = { name = "Alice" }
    person_name: String = person.name
    pair: (Int, String) = (1, "one")
    first: Int = pair[0]
    result
```

UFCS works with all functions, including imported module functions and user-defined functions. It is purely syntactic sugar — the function itself doesn't need to be defined specially. Field access has priority over UFCS, then the compiler considers imported functions, type-enabled methods, trait methods, and overload resolution.

### Automatic Method Discovery

When you import a **type** from a module, all functions in that module whose first parameter is that type become available as methods — without importing each function individually:

```blorp
import:
    heap as H: Heap  -- H.heap() plus Heap methods: h.push(v), h.pop(), h.size()

-- With the Heap type imported, these methods work automatically:
func demo_heap() -> Int:
    var h: Heap[Int] = H.heap()
    h = h.push(42)          -- UFCS: push(h, 42) from std/heap
    h = h.push(10)
    match h.pop():          -- UFCS: pop(h) from std/heap
        Some(pair): print(to_string(pair[0]))  -- prints 10 (min)
        None: void
    0
```

**Prelude types** — `Option`, `Result`, `String`, `List`, `Dict`, and `Set` — have their methods available automatically with **zero imports**:

```blorp
-- No import needed for any of these:
func demo_prelude_methods() -> String:
    items: List[Int] = [3, 1, 4, 1, 5]
    sorted: List[Int] = items.sort()         -- List.sort from std/list
    first: Option[Int] = sorted.get(0)       -- List.get from std/list
    value: Int = first.get_or(0)             -- Option.get_or from std/option
    name: String = "hello world"
    parts: List[String] = name.split(" ")    -- String.split from std/string
    upper: String = name.upper()          -- String.upper from std/string
    upper + " " + value.to_string() + " " + parts.length().to_string()
```

Auto-imported methods are **method-only** — they are not available as bare function calls. If you need the bare-name style `map(items, f)`, import the function explicitly:

```blorp
import:
    list: map            -- Now both styles work

func demo_map() -> List[Int]:
    items: List[Int] = [1, 2, 3]
    method_mapped: List[Int] = items.map(func(x): x * 2)  -- Method style
    bare_mapped: List[Int] = map(items, func(x): x * 2)   -- Bare style
    bare_mapped.append(method_mapped.length())
```

---

## 3. Type System

### Primitive Types

| Type | Size | Description | Example |
|------|------|-------------|---------|
| `Int` | 64-bit | Signed integer | `42`, `-17` |
| `Float` | 64-bit | IEEE 754 double | `3.14`, `-0.5` |
| `Bool` | - | Boolean | `True`, `False` |
| `String` | - | Immutable UTF-8 text | `"hello"` |
| `Char` | 32-bit | Unicode codepoint | `'a'`, `'\n'` |
| `Void` | - | Unit type | Return type for side-effect functions |
| `Fixed` | - | Fixed-point decimal | `fixed(19.99, 2)` |
| `Bytes` | - | Binary byte buffer | `bytes as B: Bytes` then `B.bytes(64)` |

### Sized Integers

Explicit-width integer types for low-level work, interop, and packed data:

| Signed | Unsigned | Width |
|--------|----------|-------|
| `Int8` | `UInt8` | 8-bit |
| `Int16` | `UInt16` | 16-bit |
| `Int32` | `UInt32` | 32-bit |
| `Int64` | `UInt64` | 64-bit |
| `Int128` | `UInt128` | 128-bit |

```blorp
x: Int32 = to_int32(42)
y: UInt8 = to_uint8(255)

-- Same-type arithmetic only
z: Int32 = x + to_int32(1)

-- Wrapping overflow behavior (no runtime error)
max_u8: UInt8 = to_uint8(255)
wrapped: UInt8 = max_u8 + to_uint8(1)  -- wraps to 0

-- Conversions between sizes
big: Int64 = to_int(x)

-- Bitwise operations are available for integer types
mask: Int32 = bit_and(x, to_int32(15))
```

### Sized Floats

Explicit-width floating-point types:

| Type | Width | C Type | Description |
|------|-------|--------|-------------|
| `Float` | 64-bit | `double` | Default float (IEEE 754 double) |
| `Float32` | 32-bit | `float` | Single precision |
| `Float16` | 16-bit | `_Float16` | Half precision (requires C23/Clang 15+) |

```blorp
x: Float32 = to_float32(3.14)
y: Float16 = to_float16(1.5)

-- Same-type arithmetic only (no implicit promotion)
z: Float32 = x + to_float32(1.0)

-- Convert between sizes
big: Float = to_float(x)
```

All three float types support full fixed-size array operations.

### Tuples

Fixed-size, heterogeneous collections (2-4 elements):

```blorp
func tuple_examples() -> Int:
    pair: (Int, String) = (42, "answer")
    triple: (Bool, Int, Float) = (True, 1, 3.14)

    -- Access by compile-time index (0-indexed)
    first: Int = pair[0]
    second: String = pair[1]

    -- Destructuring
    (a, b) = pair
    (_, y) = pair   -- Ignore first element
    0
```

### Lists

Dynamic-size, homogeneous collections with COW semantics:

```blorp
numbers: List[Int] = [1, 2, 3]
empty: List[String] = []

-- Operations (all pure, return new lists via COW)
updated: List[Int] = numbers.append(4)
elem: Option[Int] = numbers.get(0)
len: Int = numbers.length()
```

### Fixed-Size Arrays

Compile-time sized numeric arrays use postfix dimensions on the element type. `Float[#4]` is a 1D vector, `Float[#2, #3]` is a 2D matrix, and `Float[#2, #3, #4]` is a higher-rank array. Plain `Float` is the scalar form.

At runtime there is one builtin tensor container. Array values are stored in flat row-major order.

> **New to blorp?** You can use vectors and matrices without understanding dimension parameters.
> Just use concrete sizes like `Float[#4]` and everything works. The `#N` generic
> dimension system and variadic `#Ds...` are advanced features for writing reusable library
> code — you can skip those sections and come back when you need them.

```blorp
-- 1D array (vector shape)
v: Float[#4] = {1.0, 2.0, 3.0, 4.0}
w: Int[#3] = {10, 20, 30}

-- 2D array (matrix shape)
m: Float[#2, #3] = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}}

-- Higher-dimensional array
t: Float[#2, #3, #4] = ...

-- Variadic dimensions (#Ds...): generic over array shape.
-- Named variadic dims work like type variables for dimensions — they mean
-- "the caller provides the concrete dimensions", NOT "unknown size."
-- They can only appear in array types, and must be the last dimension.
-- Concrete dimensions flow through at the call site:
func count_elements[T](data: T[#Ds...]) -> Int:
    length(data)

v5: Int[#5] = {1, 2, 3, 4, 5}
n: Int = count_elements(v5)   -- returns 5, v5's #5 flows through #Ds...

-- Named sharing: same name in param and return preserves concrete dims
pure func set_all[T](arr: T[#Ds...], val: T) -> T[#Ds...]:
    ...
z: Int[#5] = set_all(v5, 0)  -- #5 preserved through #Ds...

-- Different names resolve independently:
pure func swap(a: T[#As...], b: T[#Bs...]) -> (T[#Bs...], T[#As...]):
    (b, a)

-- Dimension variables can also be used as parameter types:
pure func matrix[T, #N, #M](value: T, rows: #N, cols: #M) -> T[#N, #M]:
    builtin

-- Constructors require static dimension evidence from their size arguments.
-- A literal, #N parameter, length(array), or arithmetic over those forms works.
pure func zeros_like[#N](src: Float[#N]) -> Float[#N]:
    n: #N = src.length()
    vector(0.0, n)

-- IMPORTANT: variadic dims are NOT for runtime-sized data. Array dimensions
-- must always be known at compile time. A type annotation like Float[#5]
-- does not make vector(0.0, some_runtime_int) safe. For dynamically-sized
-- collections (sizes from config files, user input, etc.), use List[T] instead.

-- Wildcard dims (#_ and #_...): "don't care about this dimension."
-- Use them in parameter positions when the function doesn't need to know
-- or reflect the dimension in its return type.
pure func length(arr: T[#_...]) -> Int:
    builtin      -- Works on any array rank — length ignores all dims.

pure func get(arr: T[#_], i: Int) -> Option[T]:
    builtin      -- Works on any 1D array regardless of size.

-- Each call site freshens #_ independently, so different call sites
-- can pass tensors of different sizes without unifying them together.
-- Rule of thumb: use #_ when a dimension must be present but its value
-- is irrelevant; use named #N or #Ds... when the value must flow through
-- into the return type or another parameter.

-- Element-wise operations
sum: Float[#4] = v + v
scaled: Float[#4] = v * 2.0

-- Subscript access (compile-time bounds checked)
val: Float = v[2]

-- Range slicing
slice: Float[#3] = v[1..4]
```

#### Peeling Semantics

Array operations work on the first dimension.

```blorp
m: Float[#2, #3] = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}}
row: Float[#3] = m[0]            -- peel one dimension
cell: Float = m[0, 1]            -- fully index to an element

t: Int[#2, #3, #4] = tensor3(0, 2, 3, 4)
face: Int[#3, #4] = t[0]
```

Single-index subscript peels one dimension. Multi-index subscript returns an element once you provide one index per dimension.

#### Vector Operations

Vector reductions take advantage of fixed positive dimensions. `argmax` and
`argmin` seed from the first element, require only `Orderable`, and return a
range-refined index, so their result can be used directly where `..#N` is
required:

```blorp
import:
    vector: argmax, argmin


values: Int[#4] = {3, 7, 1, 5}
highest_index: ..#4 = values.argmax()
lowest_index: ..#4 = values.argmin()
```

#### Matrix Operations

Matrices use the same tensor arithmetic rules as vectors. `a * b` is
elementwise multiplication for same-shaped matrices; linear algebra operations
use explicit names from `std/matrix`.

```blorp
import:
    matrix: multiply, multiply_vector, outer, transpose


a: Float[#2, #3] = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}}
b: Float[#3, #2] = {{7.0, 8.0}, {9.0, 10.0}, {11.0, 12.0}}
result: Float[#2, #2] = a.multiply(b)

weights: Float[#2, #3] = a
input: Float[#3] = {1.0, 0.5, 0.25}
output: Float[#2] = weights.multiply_vector(input)
outer_result: Float[#2, #3] = output.outer(input)

scaled: Float[#2, #3] = a * 2.0       -- scalar broadcast
same_shape: Float[#2, #3] = a * a     -- elementwise
flipped: Float[#3, #2] = a.transpose()
```

The dedicated matrix kernels support the standard `Numeric` element types:
`Int`, `Float`, `Float32`, and `Float16`. Other element types can still use
shape-preserving helpers such as `map`, `zip_map`, `min`, `max`, `diagonal`,
and row/column access when their trait bounds are satisfied.

Shape-preserving matrix transforms use explicit higher-order helpers. `map`,
`map_indexed`, and `zip_map` return a matrix with the same row and column
dimensions. `fold`, `sum`, `product`, `mean`, `all`, and `any` consume
matrix cells in row-major order. Fixed matrix dimensions are positive, so seeded
operations are infallible:
`min`, `max`, `argmin`, `argmax`, `to_row_major_vector`, and
`from_row_major_vector`:

```blorp
import:
    matrix: all, argmax, argmin, product, fold, from_row_major_vector, map, map_indexed, max, mean, min, sum, to_row_major_vector, zip_map


values: Int[#2, #3] = {{1, 2, 3}, {4, 5, 6}}
doubled: Int[#2, #3] = values.map(pure func(x: Int): x * 2)
indexed: Int[#2, #3] = values.map_indexed(pure func(row: ..#2, col: ..#3, x: Int): x + row + col)
combined: Int[#2, #3] = values.zip_map(doubled, pure func(a: Int, b: Int): a + b)
folded_total: Int = values.fold(0, pure func(acc: Int, x: Int): acc + x)
total: Int = values.sum()
multiplied: Int = values.product()
highest: Int = values.max()
highest_cell: (..#2, ..#3) = values.argmax()
lowest_cell: (..#2, ..#3) = values.argmin()
average: Float = values.mean()
all_positive: Bool = values.all(pure func(x: Int): x > 0)
flat: Int[#6] = values.to_row_major_vector()
rebuilt: Int[#2, #3] = from_row_major_vector(flat, 2, 3)
```

Runtime-indexed matrix cell access uses `get`/`get_or` with row and column
arguments. First-dimension tensor access uses the same names with one index, so
resolution stays type- and arity-directed. Use row helpers when the index
selects a whole row. `get_column` returns `None` when the column is out of
bounds; `get_column_or` accepts a fallback value instead:

```blorp
import:
    matrix: column_count, diagonal, get, get_or, get_column, get_column_or, get_row, get_row_or, identity, row_count, set_cell, set_column, set_diagonal, set_row, trace


m: Int[#2, #3] = matrix(0, 2, 3)
rows: #2 = m.row_count()
columns: #3 = m.column_count()
maybe_cell: Option[Int] = m.get(1, 2)
cell: Int = m.get_or(1, 2, -1)
maybe_row: Option[Int[#3]] = m.get_row(1)
row: Int[#3] = m.get_row_or(1, {0, 0, 0})
maybe_column: Option[Int[#2]] = m.get_column(2)
column: Int[#2] = m.get_column_or(2, -1)
updated: Int[#2, #3] = m.set_cell(1, 2, 42)
with_row: Int[#2, #3] = m.set_row(1, {7, 8, 9})
with_column: Int[#2, #3] = m.set_column(2, {10, 11})

square: Int[#2, #2] = {{1, 2}, {3, 4}}
diag: Int[#2] = square.diagonal()
total: Int = square.trace()
replaced_diag: Int[#2, #2] = square.set_diagonal({10, 20})
identity: Int[#2, #2] = identity(2)
```

#### Scoped Vector Parallelism

Fixed-size vectors use `Vector.parallel` for parallel shape-preserving
pipelines. The callback receives a `ParallelVector[T, #N]` view. That scoped
view exposes only operations that keep the exact same `#N` shape: `map`,
`map_indexed`, and `zip_map`.

```blorp
import:
    vector: ParallelVector, parallel


pure func combine[#N](left: Int[#N], right: Int[#N]) -> Int[#N]:
    left.parallel(pure func(chunk: ParallelVector[Int, #N]):
        chunk
            .zip_map(right, pure func(a: Int, b: Int): a + b)
            .map_indexed(pure func(i: ..#N, value: Int): value + i)
            .map(pure func(value: Int): value * 2)
    )
```

`ParallelVector` intentionally does not support `filter`, `length`, indexing,
iteration, or conversion back to a normal vector inside the callback. The
callback returns a `ParallelVector[U, #N]`; `parallel` materializes the result
as a normal `U[#N]` vector after the pipeline completes.

#### Scoped Matrix Parallelism

Fixed-size matrices use the same scoped pattern with row and column dimensions
preserved. The callback receives a `ParallelMatrix[T, #M, #N]` view and can use
`map`, `map_indexed`, and `zip_map`.

```blorp
import:
    matrix: ParallelMatrix, parallel


pure func combine[#M, #N](left: Int[#M, #N], right: Int[#M, #N]) -> Int[#M, #N]:
    left.parallel(pure func(chunk: ParallelMatrix[Int, #M, #N]):
        chunk
            .zip_map(right, pure func(a: Int, b: Int): a + b)
            .map_indexed(pure func(row: ..#M, col: ..#N, value: Int): value + row + col)
            .map(pure func(value: Int): value * 2)
    )
```

`ParallelMatrix` does not support `filter`, row/column extraction, indexing,
iteration, transpose, or conversion back to a normal matrix inside the callback.
The scoped operations preserve the exact `#M, #N` shape, and `parallel`
materializes a normal `U[#M, #N]` matrix after the pipeline completes.

#### Dimension Arithmetic

Type-level dimension expressions allow computing output shapes from input shapes:

```blorp
-- Arithmetic on dimension parameters
func concat[T, #M, #N](a: T[#M], b: T[#N]) -> T[#M + #N]:
    ...

func tile[T, #N](v: T[#N], times: Int) -> T[#N * 2]:
    ...

func tail[T, #N](v: T[#N]) -> T[#N - 1]:
    ...

func split_half[T, #N](v: T[#N]) -> (T[#N / 2], T[#N / 2]):
    ...

-- Concrete dimensions work too
func pad[T, #N](v: T[#N]) -> T[#N + 1]:
    ...
```

Dimension arithmetic supports `+`, `-`, `*`, and `/` on `#`-prefixed
dimension variables and integer literals. When all operands are concrete, the
compiler evaluates the expression at compile time (for example, `#3 + #2`
becomes `#5`). Dimension division must be exact, and dimension expressions must
resolve to valid non-negative dimensions.

Function signatures can add `where` constraints when one computed dimension
must equal another. Constraints are checked when concrete dimensions are known:

```blorp
pure func concat_check[T, #M, #N, #R](
    a: T[#M],
    b: T[#N],
    c: T[#R],
) -> Int where #M + #N == #R:
    length(a) + length(b) + length(c)

valid_total: Int = concat_check({1, 2}, {3, 4, 5}, {1, 2, 3, 4, 5})
```

#### Tensor Loop Views

Tensor iteration helpers live in `std/tensor` and should be imported
explicitly. As ordinary values they have list-shaped signatures; in `for`
position, the compiler lowers them to direct loops instead of materializing an
intermediate list.

```blorp
import:
    tensor: enumerate, indices, windows

pure func sum_by_index(v: Int[#5]) -> Int:
    var total: Int = 0
    for i in indices(v):
        total += v[i]
    total

pure func sum_pairs(v: Int[#5]) -> Int:
    var total: Int = 0
    for (i, x) in enumerate(v):
        total += i + x
    total

pure func sum_windows(v: Int[#5]) -> Int:
    var total: Int = 0
    for w in windows(v, 3):
        total += w[0] + w[1] + w[2]
    total
```

`indices` yields range-refined indices, so subscripts using the loop variable
are compile-time bounds checked. `enumerate2` provides `(row, col, value)`
triples for matrices.

#### Runtime Shape Refinement with assert_shape

When working with variadic-dimension arrays (`T[#Ds...]`), you can refine them to a known size at runtime using `assert_shape`:

```blorp
-- assert_shape(array, N) returns Option[T[#N]]
-- Refines variadic dims to a concrete dimension if the runtime length matches
func process(data: Float[#Ds...]) -> Option[Float]:
    v ?= assert_shape(data, 4)    -- v: Float[#4]
    Some(v[0] + v[1] + v[2] + v[3])

-- Works with match too
func check(t: Int[#Ds...]) -> Bool:
    match assert_shape(t, 10):
        Some(validated):
            length(validated) == 10
        None:
            False
```

Note: Variadic dims (`#N...`) are only valid in array dimension suffixes. Since concrete dimensions flow through named variadic dims at call sites, most code should use specific dimension parameters (`#N`, `#M`) rather than variadic dims.

`assert_shape` requires a **positive compile-time integer literal** as the expected length. Variable expressions are not allowed — the compiler must know the target dimension statically.

`assert_shape` refines the first dimension only. It checks `length(t) == N` and returns the same tensor value on success; it does not reshape or copy data.

Array operations are SIMD-accelerated (SSE2/NEON) for Float and Int element
types. Arrays are heap-allocated with ARC and COW optimization.

### Dictionaries

Insertion-ordered key-value maps with copy-on-write semantics. Iteration
preserves the order keys were inserted; removing a key preserves the
relative order of remaining keys.

```blorp
import:
    dict as D

func dict_examples() -> Int:
    map: Dict[String, Int] = D.dict()
    reserved: Dict[String, Int] = D.with_capacity(128)
    map2: Dict[String, Int] = D.set(map, "key", 42)
    val: Option[Int] = D.get(map2, "key")
    exists: Bool = D.contains(map2, "key")
    map3: Dict[String, Int] = D.remove(map2, "key")

    -- Dict literal syntax
    scores: Dict[String, Int] = {"alice" => 95, "bob" => 87}
    empty: Dict[String, Int] = {}

    -- Create from list of pairs
    ages: Dict[String, Int] = D.from_list([("Alice", 30), ("Bob", 25)])

    -- Iterate keys (zero allocation, insertion order)
    for k in scores:
        print(k)

    -- Iterate key-value pairs (zero allocation, insertion order)
    for (k, v) in scores:
        print(k + ": " + to_string(v))

    -- Extract as lists (insertion order)
    ks: List[String] = D.keys(scores)
    vs: List[Int] = D.values(scores)
    es: List[(String, Int)] = D.entries(scores)
    0
```

### Sets

Hash sets with COW semantics. Use qualified import:

```blorp
import:
    set as S

s: Set[Int] = S.set()
s2: Set[Int] = S.add(s, 42)
has: Bool = S.contains(s2, 42)
s3: Set[Int] = S.remove(s2, 42)
items: List[Int] = S.to_list(s2)
```

### Records

Named product types with field access:

```blorp
record Person {
    name: String,
    age: Int
}

record Point[T] {
    x: T,
    y: T
}

record Samples[#N] {
    values: Float[#N]
}

-- Construction
p: Person = {name = "Alice", age = 30}

-- Field access
name: String = p.name

-- Record update (COW: mutates in-place when unique, copies when shared)
p2: Person = {p | age = 31}
p3: Person = {p | name = "Bob", age = 25}

-- Self-update pattern: guaranteed in-place mutation (refcount is 1)
var player: Person = {name = "Alice", age = 30}
player = { player | age = player.age + 1 }
```

### Structs (Value Types)

Stack-allocated value types with no ARC overhead:

```blorp
struct Color {r: UInt8, g: UInt8, b: UInt8, a: UInt8}

c: Color = {r = to_uint8(255), g = to_uint8(0), b = to_uint8(0), a = to_uint8(255)}
red: UInt8 = c.r
```

Structs support the same update syntax as records:

```blorp
struct Vec2 {x: Float, y: Float}

v: Vec2 = {x = 1.0, y = 2.0}
moved: Vec2 = { v | x = v.x + 10.0 }   -- stack copy, zero allocation
```

Structs cannot have type parameters. Use a `record` when the data shape needs
generic type parameters or dimension parameters such as `#N`.

#### When to Use Struct vs Record

**Default to `record`.** Use `struct` only when you need stack allocation for performance.

| | `record` | `struct` |
|---|---|---|
| **Allocation** | Heap (ARC + COW) | Stack (value copy) |
| **Copying cost** | Cheap (bumps refcount) | Copies all fields |
| **Best for** | General-purpose data, collections, anything with String/List fields | Small, fixed-size data with only primitive fields |
| **Examples** | `Person`, `Config`, `HttpRequest` | `Color`, `Vec2`, `RGBA`, `FilterState` |

Rule of thumb: if all fields are primitives (Int, Float, Bool, sized ints) and there are fewer than ~8 fields, `struct` is a good fit. If any field is a String, List, or another record, use `record` — the ARC machinery is already needed for those fields anyway.

### Union Types (Sum Types / ADTs)

```blorp
union Option[T]:
    Some(T)
    None

union Result[T, E]:
    Ok(T)
    Err(E)

union Shape:
    Circle(Float)
    Rectangle(Float, Float)
    Triangle(Float, Float, Float)
```

Constructing:

```blorp
opt: Option[Int] = Some(42)
none: Option[Int] = None
result: Result[Int, String] = Ok(100)
err: Result[Int, String] = Err("failed")
```

### Enum Types

Enums are lightweight union types with no associated data — variants are simple named constants backed by integers:

```blorp
enum Color:
    Red
    Green
    Blue

enum Direction:
    North
    South
    East
    West
```

Enums support pattern matching (with exhaustiveness checking), equality, `to_string`, storage in lists, and use as function parameters:

```blorp
enum Color:
    Red
    Green
    Blue

pure func describe(c: Color) -> String:
    match c:
        Red: "warm"
        Green: "cool"
        Blue: "cool"

colors: List[Color] = [Red, Green, Blue]
same: Bool = Red == Red
different: Bool = Red != Blue
name: String = to_string(Red)
```

For variants that carry data (payloads), use `union` instead of `enum`.

#### Coming From Other Languages?

The naming of `union` and `enum` in blorp differs from some languages:

| Blorp | Rust | Haskell | TypeScript | Java |
|-------|------|---------|------------|------|
| `union` (variants with data) | `enum` | `data` | discriminated union | sealed interface |
| `enum` (simple named constants) | C-style enum | — | string literal union | `enum` |

If you're coming from **Rust**: blorp's `union` is Rust's `enum` (variants carry data, pattern-matchable). Blorp's `enum` is closer to a C-style enum (no payloads, just named tags).

```blorp
-- Blorp union = Rust enum (data-carrying variants)
union Shape:
    Circle(Float)
    Rectangle(Float, Float)

-- Blorp enum = Rust fieldless enum (no data, just names)
enum Direction:
    North
    South
    East
    West
```

### Type Aliases

```blorp
type alias Pair[T] = (T, T)
type alias IntPair = (Int, Int)
type alias StringMap[V] = Dict[String, V]
type alias Row[T, #N] = T[#N]
```

Aliases are transparent: `IntPair` and `(Int, Int)` are the same type.

Use `opaque type` when a module should expose a distinct API type while keeping
the same runtime representation as an existing type:

```blorp
opaque type Email = String

pure func email(raw: String) -> Email:
	into Email(raw)

pure func email_value(value: Email) -> String:
	from Email(value)
```

`Email` is not interchangeable with `String`, so callers cannot accidentally
pass arbitrary strings where an `Email` is required. `into Email(...)` and
`from Email(...)` work only in the module that defines `Email`; expose public
constructor/accessor functions when other modules need controlled access. The
compiler erases the conversion after typechecking, so the representation keeps
the same layout and optimizations as the target type.

### Generics

```blorp
-- Type parameters
func identity[T](x: T) -> T:
	x

func identity_named[Elem2](x: Elem2) -> Elem2:
	x

func swap[A, B](pair: (A, B)) -> (B, A):
	(pair[1], pair[0])

-- Numeric type parameters (compile-time integers, prefixed with #)
func add_vectors[#N](a: Float[#N], b: Float[#N]) -> Float[#N]:
	a + b
```

Generic type parameter names must start with a capital ASCII letter and contain
only ASCII letters and digits, such as `T`, `Elem`, or `Item2`. Dimension
parameters follow the same rule after `#`, such as `#N` or `#Rows`.

**Auto-generalization.** The `[T, ...]` list is optional when every generic
name already appears in the parameter or return types. The compiler
auto-generalizes any capitalized alphanumeric name (`T`, `Elem`, `Item2`) or
`#`-prefixed dimension (`#N`, `#Ds...`) that is not a defined type or alias:

```blorp
-- Explicit and auto-generalized forms are equivalent:
pure func identity_explicit[T](x: T) -> T: x
pure func identity_auto(x: T) -> T: x           -- T auto-generalized
pure func identity_named_auto(x: Elem) -> Elem: x -- Elem auto-generalized

pure func repeat_value[T, #N](v: T, n: #N) -> T[#N]:
	vector(v, n)

pure func repeat_value_auto(v: T, n: #N) -> T[#N]:
    vector(v, n)   -- both T and #N auto-generalized
```

Auto-generalization does **not** capture names that are already defined as
types (records, unions, aliases) — even if declared later in the file:

```blorp
func test(x: T) -> Int:    -- T is the union below, NOT a type parameter
    match x:
        Wrap(n): n

union T:
    Wrap(Int)
```

Use the explicit `[T]` form when you want to disambiguate, or when the name
shadows a concrete type on purpose.

Generic type parameters are opaque inside the function body. A concrete value
does not satisfy `T` unless it came from a value already typed as `T`, but the
declared return type still guides nested literals:

```blorp
record Box[K, V] {key: K, value: V}

pure func box[K, V](key: K, value: V) -> Box[K, V]:
    {key = key, value = value}

pure func bad[T]() -> T:
    42   -- error: Int is not an arbitrary T
```

### Range Refinement Types

The type `..#N` represents an integer proven to be in the range `[0, N)`.
These refinement values are distinct from the first-class `Range` struct used
by `0..10` expressions. Refinement values come from compile-time proofs: literal indices, bounded loops,
`enumerate`, modulo narrowing, or control-flow checks such as
`if i >= 0 and i < length(v):`.

```blorp
if i >= 0 and i < length(v):
    v[i]                    -- i is narrowed to the vector's range in this branch
else:
    default_val

-- Use range types as function parameters for safe indexing
pure func safe_get(v: Int[#5], i: ..#5) -> Int:
    v[i]                    -- compile-time guaranteed safe

-- Range types promote to Int for arithmetic
for idx in 0..10:
    idx + 1                 -- works: ..#10 usable as Int

-- Generic version with numeric type parameter
pure func safe_element[#N](v: Int[#N], i: ..#N) -> Int:
    v[i]
```

Range types are part of the compile-time proof system. They let the type checker accept indexing without an extra source-level bounds guard, but some generic cases still lower through checked tensor helpers until later optimization folds them away.

For arbitrary runtime indices where no proof is available, use `get` or
`get_or`. Vectors and first-dimension tensor access take one index; matrix
cell access takes row and column indices.

### Function Types

```blorp
(Int) -> Int              -- Single parameter
(Int, String) -> Bool     -- Multiple parameters
() -> Void                -- No parameters
pure (Int) -> Int         -- Pure function type

-- Pure functions are subtypes of impure (can pass pure where impure expected)
func apply(f: (Int) -> Int, x: Int) -> Int:
    f(x)

pure func double(x: Int) -> Int:
    x * 2

result: Int = apply(double, 5)  -- OK: pure satisfies impure
```

### Type Inference

```blorp
-- Variable initializers
x = 42                  -- x: Int inferred
name = "Alice"          -- name: String inferred

-- Lambda parameters (from context)
numbers.map(func(x): x * 2)  -- x: Int from List[Int]

-- Collection elements
list = [1, 2, 3]       -- List[Int] inferred

-- Where inference DOESN'T work:
-- func add(a, b) -> Int: a + b  -- Error: param types required
-- bad = func(x): x + 1          -- Error: no context for x
-- empty = []                     -- Error: no element type
```

### Expression Type Ascription

Use `expr as Type` when an expression needs an inline expected type. This is
the same kind of checked guidance as an annotated binding, not an unchecked
runtime cast.

```blorp
func accepts_float32(x: Float32) -> Bool:
    True

func accepts_names(names: List[String]) -> Bool:
    names.length() >= 0

ok1: Bool = accepts_float32(123.45 as Float32)
ok2: Bool = accepts_names([] as List[String])
ok3: Option[String] = None as Option[String]

bad1: Int = "hello" as Int           -- type error
bad2: List[String] = [1] as List[String]  -- type error
```

Ascription can appear anywhere an expression is valid, including function
arguments, collection literals, match arms, and nested expressions. It gives
the inner expression an expected type during inference, so literals and empty
collections get the same contextual treatment they would get from an annotated
assignment.

Annotated bindings provide contextual literal narrowing:

```blorp
x: Float32 = 1.0
```

Function and constructor arguments do not implicitly narrow literals to sized
numeric targets. Use `as` when the callee expects a specific sized type:

```blorp
ok: Bool = accepts_float32(1.0 as Float32)
value: Wide = WideValue(1 as Int128)
```

`as` binds lower than arithmetic, comparison, and logical operators, but higher
than comma and argument separation:

```blorp
value: Int32 = 1 + 2 as Int32          -- (1 + 2) as Int32
sum: Int32 = (1 as Int32) + (2 as Int32)
```

For actual value conversion, use the standard conversion functions such as
`to_int32` or `to_float32`.

Note that we may gradually remove type ascription as our inference matures.

---

## 4. Purity System

### Pure vs Impure

```blorp
-- Pure: no side effects, deterministic
pure func square(x: Int) -> Int:
    x * x

-- Impure: may have side effects
func greet(name: String) -> Void:
    print("Hello, ${name}")
```

**Core rule: Pure functions cannot call impure functions.**

### Local Mutation Is Allowed in Pure Functions

A pure function may use local mutable state as long as no impure functions are called:

```blorp
-- ALLOWED: Local mutation within pure function
pure func sum(nums: List[Int]) -> Int:
    var total: Int = 0
    for n in nums:
        total = total + n
    total

-- NOT ALLOWED: Calling impure function
pure func bad(x: Int) -> Int:
    print(to_string(x))    -- ERROR: print is impure
    x
```

This is safe because the function remains deterministic with no observable side effects. Given the same inputs, a pure function always produces the same output — regardless of how the implementation uses local state internally. This means you get the practical benefits of purity (safe parallelization, caching, equational reasoning) without being forced into awkward recursive patterns for simple accumulation.

### What Makes a Function Impure

| Action | Example |
|--------|---------|
| Calling impure functions | `print`, imported `system` file APIs, imported `process` APIs |
| Calling any impure function | Transitively impure |
| Taking an impure callback | `func f(cb: (Int) -> Void)` |
| Concurrency operations | `detach`, `send`, `recv`, `sleep` |

### What Does NOT Make a Function Impure

| Action | Example |
|--------|---------|
| Local `var` mutation | `var x = 0; x = x + 1` |
| For loops with accumulators | `for i in list: total = total + i` |
| Calling pure functions | `square(x)` |
| Pure callbacks | `map(items, pure func(x): x * 2)` |

### Closure Capture Rules

Closures capture values, not references. They get their own independent copy of anything they close over. This means closures can only capture immutable values — capturing `var` is a compile error:

```blorp
-- OK: Captures immutable parameter
pure func make_adder(base: Int) -> pure (Int) -> Int:
    pure func(x): x + base

-- OK: Captures immutable let binding
func make_greeter(name: String) -> () -> String:
    greeting: String = "Hello, ${name}!"
    func(): greeting

-- ERROR: Cannot capture mutable variable
func bad() -> () -> Int:
    var count: Int = 0
    func(): count = count + 1; count  -- Compile error
```

**Why this restriction exists:** If closures could capture mutable variables, two closures could share the same `var` and mutate it concurrently — breaking blorp's thread safety guarantee. Since closures capture by value (not by reference), there is no way for a closure to "see" changes to the original variable or vice versa. This is what makes closures safe to pass to `concurrent:` blocks and other threads.

**What to do instead:** Pass state explicitly via function parameters, or use immutable values with accumulator patterns:

```blorp
-- Instead of a mutable counter closure, use a pure function:
pure func apply_n_times(f: pure (Int) -> Int, start: Int, n: Int) -> Int:
    var result: Int = start
    var i: Int = 0
    while i < n:
        result = f(result)
        i += 1
    result

-- Or thread state through with fold_left:
pure func sum_items(items: List[Int]) -> Int:
    items.fold_left(0, pure func(acc: Int, x: Int): acc + x)
```

### Purity Subtyping

Pure functions are subtypes of impure functions:

```blorp
-- Pure can be passed where impure is expected
func call_it(f: (Int) -> Int) -> Int: f(42)
pure func double(x: Int) -> Int: x * 2
call_it(double)  -- OK

-- Impure CANNOT be passed where pure is expected
pure func pure_call(f: pure (Int) -> Int) -> Int: f(42)
func impure_fn(x: Int) -> Int: print("hi"); x * 2
pure_call(impure_fn)  -- ERROR
```

---

## 5. Pattern Matching

### Basic Syntax

```blorp
match value:
    pattern1: result1
    pattern2: result2
    _: default
```

The colon after the scrutinee is required. All match arms must return the same type. The compiler checks exhaustiveness.
Arms are tested from top to bottom, so earlier overlapping patterns win.

### Pattern Types

```blorp
-- Wildcard
match x:
    _: "anything"

-- Variable binding
match result:
    Ok(value): value
    Err(msg): msg

-- Literal patterns
match x:
    0: "zero"
    1: "one"
    _: "other"

-- Constructor patterns
match opt:
    Some(x): x + 1
    None: 0

-- Boolean (common for conditionals)
match x > 0:
    True: "positive"
    False: "non-positive"

-- Tuple patterns
match pair:
    (0, y): "first is zero"
    (x, 0): "second is zero"
    (x, y): "both nonzero"

-- List patterns (head/rest destructuring)
match my_list:
    []: "empty"
    [x]: "singleton"
    [x, ...rest]: "head is ${to_string(x)}"

-- Qualified constructor patterns
match val:
    Module.Variant(x): x

-- Or-patterns (multiple patterns for one arm)
match color:
    Red | Orange: "warm"
    Blue | Green: "cool"
    _: "other"

-- Or-patterns work with literals too
match key:
    'w' | 'W': move_up()
    's' | 'S': move_down()
    _: void
```

### Exhaustiveness

The compiler verifies all cases are covered for unions, booleans, and lists:

```blorp
union Color:
    Red
    Green
    Blue

-- OK: All constructors covered
match color:
    Red: "red"
    Green: "green"
    Blue: "blue"

-- OK: Wildcard covers remaining cases
match color:
    Red: "red"
    _: "other"

-- ERROR: Non-exhaustive match on type 'Color': missing constructors Blue
match color:
    Red: "red"
    Green: "green"

-- Lists require a catch-all spread pattern or wildcard to cover all lengths
match my_list:
    []: "empty"
    [x]: "one"
    [a, b, ...rest]: "two or more"
```

A spread arm with restrictive fixed elements, such as `[0, ...rest]`, only
matches lists whose head is `0`; it does not make the match exhaustive for all
non-empty lists. Add a catch-all spread arm like `[x, ...rest]` or `_` for the
remaining lists.

---

## 6. Error Handling

### Option[T]

For values that may or may not exist:

```blorp
func safe_divide(a: Int, b: Int) -> Option[Int]:
    match b == 0:
        True: None
        False: Some(a / b)

-- Using combinators
result: Int = safe_divide(10, 2)
    .map(func(x): x * 2)
    .get_or(0)

-- Chaining with and_then (not flat_map)
result2: Option[Int] = safe_divide(10, 2)
    .and_then(func(x): safe_divide(x, 3))
```

Representation note: `Option[T]` is optimized by payload type. Primitive
numeric/bool/char payloads, `Int128`/`UInt128`, range types, enums, and
`struct` value records use stack `{tag, value}` layouts. Managed payloads such
as `String`, `List[T]`, heap `record`, non-enum `union`, tuples, and functions
use an internal nullable-pointer layout. Nested options, `Ptr`, unresolved
generic payloads, and unsupported payloads stay boxed so `Some(x)` and `None`
remain distinguishable.
When a stack-option value is placed into currently-erased storage such as
tuples or closure captures, it is boxed as a compatibility fallback.
Monomorphic `List[Option[T]]` values whose payload has a stack-option layout are
already specialized further: the list stores each stack-option struct inline
rather than boxing each element. The remaining fallback is an implementation
detail of erased storage boundaries, not part of the source-language contract.

### Result[T, E]

For operations that may fail with an error:

```blorp
func parse_integer(s: String) -> Result[Int, String]:
    match s.parse_int():
        Some(n): Ok(n)
        None: Err("Invalid integer: ${s}")

func main(args: List[String]) -> Int:
    match parse_integer("42"):
        Ok(n): print("Got: ${to_string(n)}")
        Err(msg): print("Error: ${msg}")
    0
```

### ?= Bindings

`?=` binds the success value from an `Option` or `Result` and returns the
failure value from the enclosing function. The enclosing function must return
the same carrier type, and the success path must return `Some(...)` or
`Ok(...)` explicitly.

```blorp
import:
    system: read_file

func parse_lines(content: String) -> Result[List[String], String]:
    Ok(content.lines())

pure func get_value() -> Option[Int]:
    Some(1)

pure func get_other_value() -> Option[Int]:
    Some(2)

-- With Result: ?= binds Ok value, short-circuits on Err
func process_file(path: String) -> Result[Int, String]:
    content ?= read_file(path)           -- If Err, returns Err from process_file
    lines ?= parse_lines(content)        -- If Err, returns Err from process_file
    count: Int = lines.length()
    Ok(count)

-- With Option: ?= binds Some value, short-circuits on None
func maybe_compute() -> Option[Int]:
    x ?= get_value()                    -- If None, returns None from maybe_compute
    y ?= get_other_value()              -- If None, returns None from maybe_compute
    Some(x + y)

-- Type annotations on ?= bindings
func process() -> Option[Int]:
    x: Int ?= get_value()
    Some(x * 2)
```

Rules for `?=`:

- `?=` binds `Some(value)` or `Ok(value)` to the name on the left.
- `None` or `Err(error)` is returned from the enclosing carrier-returning function.
- Success values are not auto-wrapped; write `Some(value)` or `Ok(value)` explicitly.
- `?=` is rejected inside loop bodies, including `for ... concurrently(...)` bodies. Move the `?=` before the loop, use an explicit `match` in the loop, or use Option/Result combinators when failure should stay local to one iteration.
- Direct `?=` cannot unwrap a resource acquisition such as `open_read(path)`;
  use `with reader ?= open_read(path):` so cleanup ownership is installed.
- There is no bare postfix `?` operator.

### `with` Resource Scopes

`with name = acquire():` and `with name ?= acquire():` create scoped resources
with deterministic cleanup. The acquired value must have a `resource type`.
The resource binding exists only inside the body, and the compiler rejects
returning resource-typed values or scoped-derived values through the final
expression, closure capture, `detach`, `concurrent:`, or
`for ... concurrently(limit:)`.

```blorp
import:
    fs: open_read

func load_text(path: String) -> Result[String, IOError]:
    with reader ?= open_read(path):
        reader.read_text()
```

Fallible acquisition results that contain resources, such as
`Result[FileReader, IOError]`, are not ordinary values. They must be consumed by
`with name ?= ...:` rather than matched or stored directly, so the compiler can
install the cleanup edge before exposing the resource handle.

If the acquisition error needs to be converted to the enclosing function's
error type, map it in the `with ?=` header:

```blorp
import:
    fs: message, open_read

union AppError:
    Io(String)

func load_count(path: String) -> Result[Int, AppError]:
    with reader ?= open_read(path) on err => Io(message(err)):
        Ok(1)
```

The `on err => ...` mapper runs only for `Err(err)`, before the resource handle
is exposed. It must produce the exact error type of the enclosing
`Result[..., E]`. This is intentionally not `Result.map_err`; acquisition
carriers that contain resources still cannot be passed through ordinary
functions.

Source functions cannot accept resource handles as parameters or return values.
That keeps resource cleanup ownership out of ordinary value semantics. Keep
handle use inside the `with` body, and pass ordinary data to helpers.

Compilation lowers resource scopes to explicit Core cleanup nodes and emits
cleanup for normal completion, body-level `?=` short-circuit results,
`break`/`continue`, and cooperative timeout/cancellation paths. Standard-library
resource declarations may attach compiler cleanup metadata with
`resource type Name = builtin("c_cleanup_name")`; lowering uses that metadata
instead of recognizing resource names by convention.

The typed `fs` module exposes scoped opens for read, write, append,
read-write, read-append, and directory handles. The handle and entry types
`FileReader`, `FileWriter`, `FileAppender`, `FileReadWriter`,
`FileReadAppender`, `Directory`, `DirectoryEntry`, `DirectoryEntryKind`, and
`IOError` are in the prelude so they can be named in type positions without an
explicit import. Openers such as `open_read`, `open_read_append`, and
`open_dir` remain ordinary `fs` module functions and must be imported.

File operations are capability methods. Read-capable handles support
`read_text()`, `read_bytes()`, `read_chunk(n)`, `read_chunk_at(offset, n)`,
`count_lines()`, and `size()`. Write-capable handles support
`write_text(text)`, `write_bytes(data)`, and `write_chunk(data)`.
Append-capable handles support `append_text(text)`, `append_bytes(data)`, and
`append_chunk(data)`. These operations borrow the scoped handle and return typed
`IOError` results.
`reader.chunks()`, `reader.chunks_with_size(n)`, and `reader.windows(n)`
return `FallibleStream[Bytes, IOError]`; `reader.lines()` returns
`FallibleStream[String, IOError]`; `reader.bytes()` returns
`FallibleStream[UInt8, IOError]`. Consume them inside the same `with` scope with
a terminal operation such as `collect_result()`, `fold_result(...)`,
`count_result()`, `find_result(...)`, `any_result(...)`, or `all_result(...)`.
A non-positive explicit chunk size or window size is reported as
`Err(InvalidInput(...))` by the terminal operation. Streams are one-shot cursors,
so they cannot be bound globally or stored in ordinary aggregates such as
tuples, lists, dicts, records, structs, or unions, and they cannot be hidden
inside ordinary carrier type aliases/ascriptions such as
`type alias MaybeStream = Option[Stream[T]]` or
`None as Option[Stream[T]]`. Ordinary local bindings such as
`maybe: Option[Stream[T]] = None` and ordinary function signatures containing
stream carriers such as `Option[Stream[T]]` are rejected too. Function values
may directly produce streams, such as `() -> Stream[T]`, but their parameters
and return values cannot hide streams in ordinary carriers such as
`() -> Option[Stream[T]]`. Generic records and unions are checked after
substitution, so wrappers are judged by what their fields or variants actually
carry. They also cannot be captured by closures, `detach`, or concurrent task
bodies. Keep a stream in a direct local binding while building a pipeline, then
consume it with a terminal operation. Create and consume a stream inside the
task when concurrent work needs its own stream.

Directory handles support `read_entry()` for manual single-entry loops,
`read_next_entries()` for explicit fixed-size batch loops, and `entries()` for
fallible-stream consumers. `read_entry()` returns `Ok(Some(entry))` until the
directory is exhausted, then `Ok(None)`.
`read_next_entries(dir, max_entries)` advances the directory handle and returns
up to `max_entries` entries from the next batch. It returns `Ok([])` after
exhaustion and rejects non-positive batch sizes with `Err(InvalidInput(...))`.
`.` and `..` are skipped. Each `DirectoryEntry` contains a basename and a
`DirectoryEntryKind` value such as `EntryFile`, `EntryDirectory`, or
`EntrySymlink`.
`ResourceSource[R, E]` is the reserved source type for future APIs that produce
owned resources one at a time, such as TCP listener connections or database
pool checkouts. It is not usable as an ordinary collection: records, unions,
type aliases that hide it inside ordinary carriers, ordinary local bindings
such as `Option[ResourceSource[...]]`, ordinary carrier type ascriptions such
as `None as Option[ResourceSource[...]]`, globals, and ordinary source function
parameters or returns cannot contain it. Function values may directly produce
resource sources, such as `() -> ResourceSource[R, E]`, but their parameters
and return values cannot hide resource sources in ordinary carriers such as
`() -> Option[ResourceSource[R, E]]`. Direct source locals must be immutable,
must come from producer calls rather than copies of existing source locals, and
must not be discarded or returned from concurrent tasks. The
sequential iteration syntax for resource sources transfers each produced
resource into a scoped loop body that owns cleanup. Concurrent resource-source
iteration is still part of the concurrency and resource roadmap.
`net/tcp.connections_stop_on_error` and
`net/tcp.connections_continue_on_error` already expose the TCP producer shape as
ARC-owned source wrappers that borrow their scoped listener and have type
`ResourceSource[TcpStream, TcpError]` so the ownership category and source-error
policy are explicit.
`writer.write_chunk(data)` performs one write attempt and returns the number of
bytes written; use `writer.write_bytes(data)` when all bytes must be written
before returning.

```blorp
import:
    fs: open_read
    stream: collect_result

func load_in_chunks(path: String) -> Result[Int, IOError]:
    with reader ?= open_read(path):
        parts ?= reader.chunks_with_size(4096).collect_result()
        Ok(parts.length())
```

For line counts, prefer the reader helper when the lines themselves are not
needed:

```blorp
import:
    fs: open_read

func line_count(path: String) -> Result[Int, IOError]:
    with reader ?= open_read(path):
        reader.count_lines()
```

TCP listeners and streams are scoped resources. Acquire them with `with` so the
compiler installs cleanup, and return ordinary data from the block. TCP APIs
return `TcpError`; wrapper-owned invalid inputs such as bad ports, backlog
values, timeouts, and chunk sizes are `InvalidInput`, while runtime-originated
socket failures are currently preserved as `Other`. Endpoints are explicit typed
values: use `Port` for concrete ports, `listen_*_any_port` when the OS should
choose an ephemeral listener port, `IpAddress` for numeric addresses, and
`DnsName` when hostname resolution is intended. Loopback and validated numeric
IP paths are virtual-thread-friendly; DNS resolution may still block an OS
worker before the socket operation can park the current fiber.
`connections_stop_on_error(listener)` and
`connections_continue_on_error(listener)` return direct
`ResourceSource[TcpStream, TcpError]` values. The source value is an ARC-owned
cursor wrapper that borrows the scoped listener and carries an explicit
accept-error policy for future iteration. It cannot escape the listener's
`with` block or be captured by closures, detached work, or concurrent work.
Sequential resource-source `for` iteration transfers each accepted stream into
a scoped loop body. `for ... concurrently(limit:)` moves each accepted stream
into exactly one child task; the child task owns scoped cleanup for that stream.

```blorp
import:
    net/tcp: IpFamily(IPv4), TcpError, connect_loopback, port, read_chunk

func fetch_once(port_num: Int) -> Result[Int, TcpError]:
    remote ?= port(port_num)
    with stream ?= connect_loopback(IPv4, remote):
        data ?= read_chunk(stream, 4096)
        Ok(data.length())
```

For repeated reads, `chunks(stream, max_bytes)` creates a scoped
`FallibleStream[Bytes, TcpError]`. Terminal operations return `Result`, so read
failures remain explicit and an empty peer read is treated as normal end of
stream. `lines(stream)` yields text lines with the same framing as file lines:
trailing `\n` and optional `\r` are removed, and a final unterminated line is
yielded when the peer closes.

```blorp
import:
    net/tcp: IpFamily(IPv4), TcpError, chunks, connect_loopback, lines, port
    stream: fold_result

func count_bytes(port_num: Int) -> Result[Int, TcpError]:
    remote ?= port(port_num)
    with stream ?= connect_loopback(IPv4, remote):
        chunks(stream, 16 * 1024)
            .fold_result(0, func(total: Int, chunk: Bytes): total + chunk.length())

func count_lines(port_num: Int) -> Result[Int, TcpError]:
    remote ?= port(port_num)
    with stream ?= connect_loopback(IPv4, remote):
        lines(stream)
            .fold_result(0, func(total: Int, line: String): total + 1)
```

Module-qualified calls work too. A combined import can provide both the module
alias and the error type:

```blorp
import:
    net/tcp as Tcp: IpFamily(IPv4), TcpError

func local_stream_port(port_num: Int) -> Result[Int, TcpError]:
    remote ?= Tcp.port(port_num)
    with stream ?= Tcp.connect_loopback(IPv4, remote):
        Tcp.stream_local_port(stream)
```

Sequential connection-source loops are useful for single-accept flows and for
code that wants to decide its own fan-out shape:

```blorp
import:
    net/tcp as Tcp: IpFamily(IPv4), TcpError

func accept_one() -> Result[Int, TcpError]:
    with listener ?= Tcp.listen_loopback_any_port(IPv4, 1):
        var seen: Int = 0
        for conn in Tcp.connections_stop_on_error(listener):
            _ = Tcp.stream_local_port(conn)
            seen += 1
            break
        Ok(seen)
```

Concurrent connection-source loops are useful for server-style fan-out. The
source is pulled by the parent task, and each accepted stream is transferred
into one child task:

```blorp
import:
    net/tcp as Tcp: IpFamily(IPv4), TcpError

func serve_until_timeout() -> Result[Void, TcpError]:
    http_port ?= Tcp.port(8080)
    with listener ?= Tcp.listen_loopback(IPv4, http_port, 128):
        ignored ?= Tcp.set_timeout(listener, 1000)
        for conn in Tcp.connections_stop_on_error(listener) concurrently(limit: 128):
            _ = Tcp.stream_local_port(conn)
        Ok(void)
```

For HTTP servers, keep resource operations in the connection loop and factor
application behavior over ordinary data. For example, a pure route function can
accept `net/http.Request` and return `net/http.Response`, while the loop owns
the scoped `TcpStream` read/write calls. Ordinary user functions still cannot
accept `TcpStream` resources; that restriction keeps cleanup ownership
compiler-visible.

`with ?=` follows the same loop restriction as direct `?=`. If acquisition is
inside loop control flow, use an explicit `match` around the loop or keep the
resource scope outside the loop body.

### debug: Blocks

Use `debug:` blocks for diagnostic code that should stay visibly separate
from program logic. A `debug:` block is a statement-level block and returns
`Void`, so it can appear in normal and `pure func` bodies:

```blorp
import:
    debug as dbg

pure func score(value: Int) -> Int:
    debug:
        dbg.log("value=${value}")
        dbg.log("debug=${dbg.debug_string(value)}")
        dbg.info("type=${dbg.type_name(value)}")
    value * 2
```

Inside a `debug:` block, the compiler rejects assignment and impure calls.
Use it for debug logging, diagnostic rendering with `debug_string`, reflection
helpers such as `type_name` / `is_heap`, and pure formatting or computation
needed to build diagnostic messages.
Normal builds erase `debug:` block bodies in Core. `--debug` builds and
`blorp test` retain the bodies, so tests can use debug-only assertions without
putting diagnostic code in normal binaries.
Functions declared `@debug_only` can only be called or referenced inside a
`debug:` block unless the program is compiled with `--debug` or by
`blorp test`. The `std/debug` logging and reflection helpers are all
debug-only APIs. Debugger breakpoints are intentionally not included in the
preview debug API.

### get_or Pattern

For providing defaults without match:

```blorp
import:
    dict as D

items: List[Int] = [1, 2, 3]
val: Int = items.get(5).get_or(0)

config: Dict[String, String] = D.from_list([("name", "blorp")])
name: String = config.get("name").get_or("default")
```

---

## 7. Traits

### Declaring Traits

```blorp
trait Equatable:
    equals
    not_equals

trait Orderable: Equatable:
    less_than
    greater_than
    less_than_or_equal
    greater_than_or_equal

trait Negatable:
    negate
```

### Implementing Traits

Trait implementations are written in a separate `implements` block — not inside the type definition. This keeps types and behavior cleanly separated:

```blorp
-- Define a record
record Color {r: Int, g: Int, b: Int}

-- Implement Stringable so to_string() works on Color
implements Stringable for Color:
    pure func to_string(c: Color) -> String:
        "rgb(${to_string(c.r)}, ${to_string(c.g)}, ${to_string(c.b)})"

-- Implement Equatable so == and != work on Color
implements Equatable for Color:
    pure func equals(a: Color, b: Color) -> Bool:
        a.r == b.r and a.g == b.g and a.b == b.b

-- Now both work:
func main(args: List[String]) -> Int:
    c: Color = {r = 255, g = 0, b = 0}
    print(to_string(c))      -- "rgb(255, 0, 0)"
    same: Bool = c == {r = 255, g = 0, b = 0}
    0
```

Traits can also be implemented for generic types you own, with inline bounds on type parameters:

```blorp
record Labeled[T: Stringable] { value: T }

implements Stringable for Labeled[T: Stringable]:
    pure func to_string[T: Stringable](label: Labeled[T]) -> String:
        "Label(${to_string(label.value)})"
```

The key idea: an `implements` block connects behavior to a type after the type definition, but coherence still applies. Put an implementation in the module that owns the trait or the module that owns the type. To add behavior to a type you do not own, wrap it in a local record first.

### Operator Overloading

Arithmetic operators (`+`, `-`, `*`, `/`, `%`, unary `-`) dispatch through traits. Implement the corresponding trait for your type and the operator just works:

```blorp
struct Vec2 {x: Float, y: Float}

implements Addable for Vec2:
    pure func add(a: Vec2, b: Vec2) -> Vec2:
        {x = a.x + b.x, y = a.y + b.y}

implements Subtractable for Vec2:
    pure func subtract(a: Vec2, b: Vec2) -> Vec2:
        {x = a.x - b.x, y = a.y - b.y}

implements Multipliable for Vec2:
    pure func multiply(a: Vec2, b: Vec2) -> Vec2:
        {x = a.x * b.x, y = a.y * b.y}

implements Negatable for Vec2:
    pure func negate(a: Vec2) -> Vec2:
        {x = -a.x, y = -a.y}

-- Now operators work directly:
a: Vec2 = {x = 1.0, y = 2.0}
b: Vec2 = {x = 3.0, y = 4.0}
c: Vec2 = a + b          -- {x = 4.0, y = 6.0}
d: Vec2 = a * b          -- {x = 3.0, y = 8.0}
e: Vec2 = -a             -- {x = -1.0, y = -2.0}
```

Similarly, implement `Equatable` for `==`/`!=` and `Orderable` for `<`, `>`, `<=`, `>=`:

```blorp
struct Vec2 {x: Float, y: Float}

implements Equatable for Vec2:
    pure func equals(a: Vec2, b: Vec2) -> Bool:
        a.x == b.x and a.y == b.y
```

The standard library uses this extensively — `Vec2`, `Vec3`, `Radians`, `Degrees`, `Hz`, `Db`, and all sized numeric types define operators through traits. See `std/geometry.brp` and `std/units.brp` for examples.

### Using Trait Bounds

```blorp
func max_val[T: Orderable](a: T, b: T) -> T:
    match a > b:
        True: a
        False: b

func print_all[T: Stringable](items: List[T]) -> Void:
    for item in items:
        print(to_string(item))

-- Multiple bounds
func compare_and_print[T: Orderable + Stringable](a: T, b: T) -> Void:
    if a < b:
        print("${to_string(a)} < ${to_string(b)}")
    else if a == b:
        print("${to_string(a)} == ${to_string(b)}")
    else:
        print("${to_string(a)} > ${to_string(b)}")
```

### Standard Traits

| Trait | Required Functions | Description |
|-------|-------------------|-------------|
| `Addable` | `add` | Addition (`+`) |
| `Subtractable` | `subtract` | Subtraction (`-`) |
| `Multipliable` | `multiply` | Multiplication (`*`) |
| `Divisible` | `divide` | Division (`/`) |
| `Modulable` | `remainder` | Modulo (`%`) |
| `Negatable` | `negate` | Unary negation (`-a`) |
| `Numeric` | `add`, `multiply`, `zero` | Basic numeric reductions |
| `Equatable` | `equals`, `not_equals` | Equality (`==`, `!=`) |
| `Orderable` | Equatable + `less_than`, `greater_than`, `less_than_or_equal`, `greater_than_or_equal` | Ordering |
| `Stringable` | `to_string` | String conversion |
| `ToBool` | `to_bool` | Boolean conversion |
| `HasLength` | `length` | Length |
| `Collection` | `length`, `is_empty` | Collection basics |

Traits are implemented for: `Int`, `Float`, `String`, `Bool`, `Char`, `Option[T]`, `Result[T, E]`, `List[T]`.

---

## 8. Modules and Imports

### File = Module

Each `.brp` file is a module. Path determines module name:
- `std/option.brp` -> module `option` (or `std/option` — both work)
- `./utils.brp` -> module `./utils`

### Import Block Syntax

All imports use the `import:` block syntax. Each module may only be imported once per file. The `std/` prefix is optional for standard library modules:

```blorp
import:
    option: Option(Some, None)         -- Type + constructors from std/option
    dict as D                          -- Qualified import
    heap as H: Heap                    -- Combined: qualified alias + selective symbols
    math: PI                           -- Specific constants
    float: sin, cos                    -- Specific functions

-- Project modules use relative paths in the same form:
-- import:
--     ./utils: helper1, helper2
```

Local package modules use an explicit `pkg/` prefix. A project with
`pkg/sqlite/client.brp` imports it as `pkg/sqlite/client`; the package id is the
first segment after `pkg/` (`sqlite` here). Bare imports do not search package
roots, so `sqlite/client` will not accidentally resolve a package module.
`std/` modules cannot import `pkg/` modules; keep optional native integrations
under `pkg/` and keep `std/` portable.

Wildcard imports are not supported; list the symbols you need or import the
module with an alias for qualified access.

The compiler rejects imports that are not used in the same file when that file
is checked, compiled, or run explicitly. Imported user modules are checked too;
compiler-injected prelude imports are not reported. `std/prelude.brp` is also
exempt because it is the compiler-owned re-export hub for those injected
imports.

### Selective Imports

Import specific symbols from a module using `:`. For union types, import constructors using parenthesized syntax:

```blorp
import:
    option: Option(Some, None)         -- Type with constructors
    result: Result(Ok, Err)            -- Type with constructors
    json: JsonValue, parse_json        -- Type + function
    float: sqrt                        -- Just functions
```

When you import a **type**, all functions from that module whose first parameter is that type become available as methods (see [Automatic Method Discovery](#automatic-method-discovery)):

```blorp
import:
    heap as H: Heap       -- Imports Heap type + enables h.push(), h.pop(), etc.

func demo_heap() -> Int:
    var h: Heap[Int] = H.heap()  -- heap() is the lowercase datatype factory
    h = h.push(42)               -- push() available via UFCS automatically
    0
```

### Qualified Imports

```blorp
import:
    list as L
    dict as D
    set as S

-- Qualified access for factory functions
func demo_dict() -> Int:
    var d: Dict[String, Int] = D.dict()
    d = d.set("key", 42)          -- .set() via UFCS (Dict is a prelude type)
    d.get("key").get_or(0)
```

Module aliases share the visible namespace with types, constructors, traits, functions, and top-level variables. An alias cannot reuse a name that already means something else:

```blorp
import:
    fixed as Fixed    -- error: Fixed already names the Fixed type
```

### Combined Qualified + Selective

When you need both a module alias for qualified access **and** specific symbols imported by name, use the combined form. Since each module can only be imported once, this is the way to get both:

```blorp
import:
    heap as H: Heap                -- Heap type + H.heap() qualified access
    json as J: JsonValue           -- Type imported, module aliased

func demo_heap() -> Int:
    var h: Heap[Int] = H.heap()    -- H.heap() via qualified alias
    h = h.push(42)                 -- .push() via UFCS (Heap was imported)
    0
```

### One Import Per Module

Each module may only appear once per file. If you need both selective and qualified access, use the combined form:

```blorp
-- WRONG: duplicate import
import:
    heap: Heap
    heap as H           -- error: module 'heap' is already imported

-- RIGHT: combined import
import:
    heap as H: Heap     -- selective + qualified in one line
```

### Prelude Types

The following types have their methods available **automatically with zero imports**:
- **`Option`** — `get_or`, `map`, `and_then`, `is_some`, `is_none`, etc.
- **`Result`** — `get_or`, `map`, `map_err`, `and_then`, `is_ok`, `is_err`, etc.
- **`String`** — `split`, `trim`, `starts_with`, `contains`, `upper`, `substring`, etc.
- **`List`** — `map`, `filter`, `sort`, `fold_left`, `get`, `append`, `length`, etc.
- **`Dict`** — `get`, `set`, `contains`, `keys`, `values`, `remove`, etc.
- **`Set`** — `add`, `contains`, `remove`, `to_list`, `size`, etc.

Constructors `Some`, `None`, `Ok`, and `Err` are also always available.

```blorp
-- This works with NO imports at all:
func main(args: List[String]) -> Int:
    nums: List[Int] = [5, 3, 1, 4, 2]
    sorted: List[Int] = nums.sort()
    match sorted.get(0):
        Some(v): print("smallest: " + to_string(v))
        None: print("empty list")
    0
```

### Trait Impls

Trait implementations (like `implements Addable for List[T]`) from imported modules take effect automatically — no need to import the trait itself:

```blorp
-- List + List works because std/list defines: implements Addable for List[T]
a: List[Int] = [1, 2] + [3, 4]   -- No trait import needed
```

### What Still Needs Explicit Import

- **Factory functions** — `dict()`, `from_list()`, `bytes(size)` (no instance as first param)
- **Cross-module functions** — `join(List[String], sep)` is in `string` module but first param is `List`
- **Non-prelude types** — `Heap`, `SortedMap`, `JsonValue`, etc. need an import to enable UFCS
- **Bare-name function calls** — `map(items, f)` style requires explicit `list: map`; `items.map(f)` does not

### Visibility

All top-level declarations are **public by default**. Use `private` to hide internal helpers:

```blorp
-- Public by default
func public_func(x: Int) -> Int:
    helper(x)

-- Private — not visible to importers
private func helper(x: Int) -> Int:
    x + 1
```

---

## 9. Concurrency

blorp provides structured concurrency primitives: `concurrent:` blocks for parallel computation with automatic joining, `for ... concurrently(limit: N)` for statement fan-out with explicit width, `List.concurrent(...)` for value-collecting fan-out, `detach` for fire-and-forget tasks, and `Channel[T]` for inter-thread communication.

### Concurrent Blocks

Run multiple computations in parallel and collect their results. All tasks are automatically joined at the end of the block:

```blorp
func expensive_a() -> Int:
    sleep(100)
    42

func expensive_b() -> String:
    sleep(100)
    "hello"

func main(args: List[String]) -> Int:
    -- Both run in parallel, joined at block end
    concurrent:
        a = expensive_a()
        b = expensive_b()

    -- Each binding is TaskResult[T]
    match a:
        Ok(val): print("a = ${to_string(val)}")
        Err(_): print("a failed")

    match b:
        Ok(val): print("b = ${val}")
        Err(_): print("b failed")
    0
```

Each binding in a `concurrent:` block spawns a task on the thread pool. The block waits for all tasks to complete before continuing. Each binding's type is `TaskResult[T]`, where `T` is the return type of the expression. `TaskResult[T]` is an alias for `Result[T, ConcurrencyError]`, so match with `Ok(value)` and `Err(error)`.

### Concurrent Blocks with Timeout

```blorp
func quick_computation() -> Int:
    1

func very_slow_computation() -> Int:
    sleep(1000)
    2

func timeout_example() -> Int:
    -- Timeout after 500ms — tasks that haven't completed get Err(Timeout)
    concurrent(timeout: 500):
        fast = quick_computation()
        slow = very_slow_computation()

    match fast:
        Ok(_): print("fast succeeded")
        Err(_): print("fast timed out")
    0
```

`ConcurrencyError` is a union type with variants `Timeout`,
`TaskFailed(String)`, and `Cancelled`.

Timeouts can also use typed `Duration` values from `units`:

```blorp
import:
    units: milliseconds

func typed_timeout_example() -> Int:
    concurrent(timeout: milliseconds(500)):
        result = quick_computation()
    0
```

**Note:** Timeouts are cooperative — they take effect at yield points (`sleep`,
`yield_now`, channel send/recv, task join). When a timeout fires, the timed-out task is
cancelled and the block waits for it to reach its next cancellation point before
continuing, so code after that point does not run. Resources acquired with
`with` are closed by cancellation cleanup before the task unwinds. A CPU-bound
computation loop will not be interrupted by a timeout. If you need
interruptible compute, insert periodic `yield_now()` calls.

### Concurrent Loops

Fan out side-effecting or producer work across a list. The loop joins before
execution continues. `for ... concurrently(...)` is statement-only; use
`List.concurrent(...)` when you need collected results:

```blorp
import:
    list: range

func index_page(page: Int) -> Void:
    print("indexing page ${to_string(page)}")

func main(args: List[String]) -> Int:
    pages: List[Int] = range(1, 11)

    -- The explicit limit makes task width and backpressure visible.
    for page in pages concurrently(limit: 4):
        index_page(page)

    0
```

Loop-wide timeouts accept either raw integer milliseconds or typed `Duration`
values:

```blorp
import:
    units: seconds

func index_with_deadline(pages: List[Int]) -> Void:
    for page in pages concurrently(limit: 4, timeout: seconds(2)):
        index_page(page)
```

For ordinary map-style fan-out, use the explicit list helper. It preserves
input order and returns `List[Result[U, ConcurrencyError]]`:

```blorp
func compute_square(n: Int) -> Int:
    n * n

func square_all(nums: List[Int]) -> List[Result[Int, ConcurrencyError]]:
    nums.concurrent(8, func(n: Int): compute_square(n))
```

Use `concurrent_with_timeout` when collected fan-out needs a whole-operation
deadline:

```blorp
import:
    units: seconds

func square_all_with_deadline(nums: List[Int]) -> List[Result[Int, ConcurrencyError]]:
    nums.concurrent_with_timeout(8, seconds(2), func(n: Int): compute_square(n))
```

The `limit` argument is the maximum number of active tasks. A computed value
less than 1 is treated as 1, so the helper remains infallible.

### detach (Fire-and-Forget)

Launch work on the thread pool without waiting for a result. Returns `Void`:

```blorp
func detach_example() -> Bool:
    ch: Channel[String] = channel(1)
    -- Fire and forget — no handle, no join
    detach wait_send(ch, "user logged in")
    match recv(ch):
        Some(_): True
        None: False
```

`detach` is impure — it cannot be used in pure functions.

### Channel[T]

Bounded multi-producer multi-consumer channels:

```blorp
func channel_example() -> Bool:
    -- Create a channel with capacity. Values below 1 clamp to 1.
    ch: Channel[Int] = channel(10)

    -- Blocking send/recv. wait_send exposes the sealed case in the type.
    sent: Result[Void, ChannelSealed] = wait_send(ch, 42)
    val: Option[Int] = recv(ch)            -- None once sealed and drained

    typed_ch: Channel[Int] = channel(1)
    sent_typed: Result[Void, ChannelSealed] = wait_send(typed_ch, 7)
    received_typed: Result[Int, ChannelSealed] = wait_recv(typed_ch)

    -- Non-blocking variants
    sent2: Bool = try_send(ch, 43)         -- Returns False if full
    sent3 = try_send_attempt(ch, 44)       -- Accepted, full, or sealed
    val2: Option[Int] = try_recv(ch)       -- Returns None if empty
    attempt = try_recv_attempt(ch)         -- Value, empty, or sealed
    timed = recv_timeout_attempt(ch, 10)   -- Value, timeout, or sealed

    -- Seal channel (unblocks all waiting senders/receivers)
    seal(ch)
    match sent:
        Ok(_): True
        Err(_): False
```

### For-in Over Channels

Channels support `for-in` loops for consumer patterns:

```blorp
func consume(ch: Channel[String]) -> Int:
    -- Consumer (blocking recv loop, exits once the channel is sealed and drained)
    for msg in ch:
        print(msg)
    0
```

### select

Use `select:` when a task needs to wait for whichever of several independent
events happens first. It is a statement-only concurrency primitive: the
selected branch runs synchronously in the current task, and execution continues
after the block.

```blorp
func wait_for_message_or_timeout(ch: Channel[String]) -> String:
    var result: String = "timeout"
    select:
        msg from ch:
            result = "message: ${msg}"
        sealed ch:
            result = "done"
        _ after 1000:
            result = "timeout"
    result
```

Receive arms use `name from channel:` and run only when a value is received.
`sealed channel:` runs when the channel has been sealed and drained. `_ after
timeout:` waits for an integer millisecond timeout or a typed `Duration`. If
more than one arm is ready, blorp rotates the first scanned arm across `select`
calls so a repeated loop does not permanently prefer the first branch.

`select:` is impure and cannot be used as the right-hand side of a binding.
Use local variables, channels, or function calls inside the selected branch to
communicate the outcome.

### sleep

```blorp
func pause() -> Int:
    sleep(1000)  -- Park the current fiber for 1000 milliseconds
    0
```

Use `yield_now()` when you want to cooperatively give another ready fiber a
chance to run without installing a timer. It is a scheduling hint, not an
ordering guarantee.

Use `sleep_for` when the timeout is a typed `Duration` from `units`:

```blorp
import:
    channel: sleep_for
    units: milliseconds

func typed_pause() -> Int:
    sleep_for(milliseconds(1000))
    0
```

Duration-aware wrappers use explicit names such as `sleep_for`,
`recv_timeout_attempt_for`, and `send_timeout_attempt_for`. Same-name overloads
such as `sleep(Duration)` are intentionally deferred until source-level
overloads for ordinary functions have a complete design.

`Duration` values are integer microsecond intervals with arithmetic and
ordering. Use constructors such as `microseconds`, `milliseconds`,
`seconds`, `minutes`, `hours`, `days`, and `weeks`.
Timeout APIs convert them through `to_timeout_milliseconds`, which rounds
positive sub-millisecond durations up to one millisecond and treats
non-positive durations as immediate polls. `concurrent(timeout: ...)` and
`for ... concurrently(limit: ..., timeout: ...)` perform that conversion
directly when passed a `Duration`.

### Thread Pool Configuration

```blorp
func compute_a() -> Int: 1
func compute_b() -> Int: 2

-- Query available threads
func pool_example() -> Int:
    n: Int = max_threads()

    -- Set max threads via concurrent block parameter
    concurrent(max_threads: 8):
        a = compute_a()
        b = compute_b()
    n

-- Or via CLI flag
-- ./blorp run program.brp --threads 4
```

The thread pool is lazily initialized on first concurrent operation. The `max_threads` parameter must be a positive integer literal. It sets the pool size for the first concurrent block encountered; subsequent blocks reuse the existing pool.

### Virtual Threads (Fibers)

Concurrent tasks run as lightweight fibers on the thread pool. Fibers yield cooperatively at park points (sleep, task join, channel send/recv), allowing many more tasks than OS threads:

```blorp
func process(i: Int) -> Int:
    i + 1

func fiber_example(items: List[Int]) -> List[Result[Int, ConcurrencyError]]:
    -- 50 tasks sleeping concurrently on 4 threads — completes in ~50ms, not 625ms
    items.concurrent(4, func(i: Int):
        sleep(50)
        process(i)
    )
```

Fibers are transparent to user code — no API changes needed. During the
concurrency migration, `limit` uses the existing scheduler-width machinery; the
roadmap tightens it into a per-loop active-task cap while keeping statement
fan-out and value collection as separate source forms.

### Pipeline Example

```blorp
func produce(ch: Channel[Int], start: Int, end: Int) -> Void:
    var i: Int = start
    while i < end:
        _ = wait_send(ch, i)
        i = i + 1

func main(args: List[String]) -> Int:
    ch: Channel[Int] = channel(100)

    -- Run producers and consumer concurrently
    concurrent:
        p1 = produce(ch, 0, 50)
        p2 = produce(ch, 50, 100)

    -- Producers done, seal channel
    seal(ch)

    -- Consume results
    var sum: Int = 0
    for val in ch:
        sum = sum + val
    print("Sum: ${to_string(sum)}")
    0
```

---

## 10. Operators

### Arithmetic

All arithmetic operators desugar to function calls:

| Operator | Desugars to | Example |
|----------|-------------|---------|
| `a + b` | `add(a, b)` | `1 + 2` -> `3` |
| `a - b` | `subtract(a, b)` | `5 - 3` -> `2` |
| `a * b` | `multiply(a, b)` | `2 * 3` -> `6` |
| `a / b` | `divide(a, b)` | `10 / 3` -> `3` |
| `a % b` | `remainder(a, b)` | `10 % 3` -> `1` |
| `-a` | `negate(a)` | `-5` |

### Safe Arithmetic (Default)

All arithmetic is safe and will never crash:
- **Division/modulo by zero** returns `0` (Int) or `0.0` (Float)
- **Integer overflow** wraps via two's complement
- **Float arithmetic** follows IEEE 754

### Checked Arithmetic (Opt-in)

Default division and modulo are infallible and return `0` on zero divisors. Use
checked helpers when zero divisors should be handled explicitly:

| Function | Behavior |
|----------|----------|
| `checked_div(a, b)` | Returns `Some(a / b)` or `None` on divide-by-zero |
| `checked_mod(a, b)` | Returns `Some(a % b)` or `None` on divide-by-zero |

### Comparison

| Operator | Returns |
|----------|---------|
| `a == b` | `Bool` |
| `a != b` | `Bool` |
| `a < b` | `Bool` |
| `a > b` | `Bool` |
| `a <= b` | `Bool` |
| `a >= b` | `Bool` |

### Logical

| Operator | Behavior | Example |
|----------|----------|---------|
| `a and b` | Short-circuit AND | `x > 0 and x < 10` |
| `a or b` | Short-circuit OR | `is_empty(list) or length(list) > 5` |
| `not a` | Logical negation | `not is_valid` |

`and` and `or` are keywords (not `&&`/`||`). They short-circuit: `a and b` only evaluates `b` if `a` is `True`. `a or b` only evaluates `b` if `a` is `False`.

### Compound Assignment

```blorp
func update_x() -> Int:
    var x: Int = 10
    x += 3    -- x = x + 3
    x -= 1    -- x = x - 1
    x *= 2    -- x = x * 2
    x /= 4    -- x = x / 4
    x
```

These desugar to `x = x op rhs`. The left-hand side must be a `var`-declared mutable variable. There is no `%=` operator.

### String Concatenation

```blorp
message: String = "hello" + " " + "world"
```

### Bitwise Operations (Sized Integers)

```blorp
a: Int32 = to_int32(255)
b: Int32 = to_int32(15)
c: Int32 = bit_and(a, b)       -- 15
d: Int32 = bit_or(a, b)        -- 255
e: Int32 = shift_left(a, 4)    -- 4080
```

---

## 11. Memory Model

### Immutability by Default

```blorp
x: Int = 5           -- Immutable: x is 5 forever in this scope
var y: Int = 0       -- Mutable: can be rebound
y = y + 1
```

### Automatic Reference Counting (ARC)

Heap-allocated values (String, List, Dict, Set, Records, union variants) use ARC:
- Objects are freed when their reference count drops to zero
- No garbage collector; deterministic deallocation
- Atomic reference counts for thread safety

### Copy-on-Write (COW)

> **The short version:** Pretend every assignment and update creates an independent copy.
> Write your code that way — it's always correct. The compiler automatically makes it
> fast by skipping the copy when it can prove you're the only owner. You never need to
> think about reference counts unless you're profiling performance.

Collections use COW for efficient "immutable" semantics:

```blorp
a: List[Int] = [1, 2, 3]
b: List[Int] = a.append(4)  -- If a's refcount is 1, mutates in-place
-- If shared, copies first
```

When a value is unique (refcount = 1), operations like `append`, `set_index`, and `set` mutate in-place instead of copying.

Here's the mental model in practice:

```blorp
-- You write this:
func build_list() -> List[Int]:
    var result: List[Int] = []
    var i: Int = 0
    while i < 1000:
        result = result.append(i)   -- looks like 1000 copies
        i += 1
    result

-- What actually happens: result is always unique (refcount = 1) inside
-- this function, so every append mutates in-place. Zero copies.
-- You get functional semantics with imperative performance.
```

When does a copy actually happen? Only when two live variables refer to the same data and one of them is "modified":

```blorp
a: List[Int] = [1, 2, 3]
b: List[Int] = a              -- b shares a's data (refcount = 2)
c: List[Int] = a.append(4)   -- a is shared, so this copies first
-- a is still [1, 2, 3], c is [1, 2, 3, 4]
```

In practice, most code naturally has unique ownership (building up results in loops, returning from functions), so copies are rare.

### No Cyclic Data

Blorp's value semantics guarantee that **cyclic data structures cannot exist**. This is why ARC works without a cycle collector — there are no cycles to collect.

The key properties that prevent cycles:

1. **All assignment copies.** `x = y` creates an independent value. COW defers the physical copy, but the semantics are always "independent values."
2. **Record update creates a new record.** `{ a | field = val }` produces a fresh record; it does not mutate `a`.
3. **No mutable references.** There is no way to point two values at each other after construction.
4. **Closures capture by value.** A closure gets its own copy of captured variables, not a reference back to the original.

Recursive types like `record Node { next: Option[Node] }` are allowed — they can represent trees and linked lists. But the values are always DAGs (directed acyclic graphs), never cycles:

```blorp
record Node { value: Int, next: Option[Node] }

func no_cycle_example() -> Node:
    var a: Node = { value = 1, next = None }
    b: Node = { value = 2, next = Some(a) }
    a = { a | next = Some(b) }
    a

-- a_new points to b, which points to a_old (next = None).
-- No cycle: a_new → b → a_old → None
```

The reassignment `a = { a | next = Some(b) }` creates a NEW node. The `b.next` field still points to the original `a` (before reassignment), which has `next = None`. The chain is always finite.

### Stack vs Heap

| Type | Allocation | Management |
|------|------------|------------|
| Int, Float, Bool, Char | Stack | None needed |
| Struct types | Stack | None needed |
| String, List, Dict, Set | Heap | ARC + COW |
| Records, union variants | Heap | ARC |
| Closures | Heap | ARC (captures retained) |
| Vectors | Heap | ARC + COW, SIMD for Float/Int |

See [Memory Model](MEMORY_MODEL.md) for full details.

---

## 12. Standard Library

### Module Map

This table lists the main public modules. The source of truth is the `std/` and
`pkg/` directories. Standard-library modules may be imported either as
`module: ...` or `std/module: ...`; packages always use the explicit
`pkg/...` import path.

| Module | Import Pattern | Description |
|--------|----------------|-------------|
| `std/prelude` | Auto-imported | Core visible types plus `print` / `puts` |
| `option`, `result` | Prelude types | `Option[T]`, `Result[T, E]`, constructors, and UFCS methods |
| `list`, `dict`, `set`, `string`, `bytes` | Prelude types | Core collections/text/binary types and UFCS methods |
| `int`, `float`, `bool`, `char` | Prelude types | Primitive type declarations and helpers |
| `int8`, `int16`, `int32`, `int128` | `int8: ...` | Signed sized integer modules |
| `uint8`, `uint16`, `uint32`, `uint64`, `uint128` | `uint8: ...` | Unsigned sized integer modules |
| `float16`, `float32`, `fixed` | `float32: ...` | Sized floats and fixed-point decimals |
| `math`, `stats`, `tensor`, `vector`, `matrix`, `parallel_vector`, `parallel_matrix` | `math: PI, TAU` | Numeric helpers, statistics, and fixed-size array/tensor APIs |
| `io`, `fs`, `system`, `path`, `process`, `time`, `channel` | `system: read_file` | I/O, typed filesystem resources, filesystem convenience APIs, process, path, time, and concurrency channel APIs |
| `debug`, `memory`, `instrumentation`, `log` | `debug: debug_string, type_name` | Diagnostics, memory stats, scheduler stats, timing/barrier helpers, and logging |
| `argparse`, `validation`, `uuid`, `random`, `crypto_random` | `argparse: ...` | Application utilities |
| `hash` | `hash: sha256` | Hashing helpers |
| `parser`, `regex` | `parser: ...` | Parsing and text-processing helpers |
| `json`, `toml`, `yaml`, `xml`, `html`, `csv` | `json: JsonValue, parse_json` | Data format parsers/encoders |
| `codec`, `codec_bridge` | `codec: Value` | Generic serialization and format bridge |
| `string`, `slice`, `stream` | `string: string, append_char` | String operations/building, slices, streams |
| `cache`, `parallel_list`, `deque`, `heap`, `sorted_map`, `property` | `heap: Heap` | Extended collections and infrastructure |
| `geometry`, `geographic`, `geojson`, `physics`, `units` | `geometry: Vec2` | Spatial, geographic, physics, and unit helpers |
| `dsp`, `fft`, `noise` | `dsp: ...` | Signal and procedural numeric helpers |
| `net/dns`, `net/tcp`, `net/tls`, `net/udp`, `net/websocket`, `net/http`, `net/url`, `net/mime` | `net/tcp: connect, read_chunk` | Portable networking primitives and protocol helpers |
| `pkg/compress`, `pkg/crypto`, `pkg/sqlite` | `pkg/compress: gzip` | Optional native bindings and native-backed packages |
| `pkg/net/dns`, `pkg/net/http_client`, `pkg/net/smtp`, `pkg/net/tls`, `pkg/net/udp`, `pkg/net/websocket` | `pkg/net/dns as DNS` | Native-backed networking packages, WebSocket helpers, and resource-migration placeholders |
| `terminal` | `terminal: ...` | Terminal helpers |
| `tuple`, `ptr`, `void`, `traits`, `test` | `test: TestSuite` | Core support modules and test framework |

Benchmark harness helpers live under `benchmarks/blorp/support/benchmark.brp`
and are not part of the standard library.

### Prelude and Always-Available Names

`std/prelude.brp` imports a deliberately small surface into every module:
`Bool`, `Bytes`, `Char`, `Dict`, `Float`, `Float16`, `Float32`, `Int`, `List`,
`Option(Some, None)`, `Result(Ok, Err)`, `Set`, `String`, typed filesystem resource
types (`FileReader`, `FileWriter`, `FileAppender`, `FileReadWriter`,
`FileReadAppender`, `Directory`, `DirectoryEntry`, `DirectoryEntryKind`) and
`IOError`, plus `print`, `puts`, `print_error`, `read_line`, and `input`.

There are three practical buckets of names available without an explicit import:

1. **Prelude imports** — the types, filesystem resource handles, and constructors
   listed above, plus
   console I/O helpers. `print` writes a trailing newline; `puts`
   writes without adding one; `print_error` writes to stderr. `read_line` and
   `input` return `None` at EOF. On interactive terminals, Ctrl-D produces
   `None` for that read without making later reads immediately return EOF.
2. **UFCS methods on prelude types** — `xs.map(f)`, `s.split(",")`,
   `opt.get_or(default)`, etc. work without importing the bare function name.
3. **Compiler-registered builtins** — conversion helpers, checked arithmetic,
   tensor helpers, and concurrency/channel primitives that are still global
   compiler entries.

Common compiler-registered builtins include:

| Category | Examples |
|----------|----------|
| Conversion | `to_string`, `to_int`, `to_float`, `to_bool`, `to_char`, `fixed` |
| Numeric traits | `abs`, `min`, `max`, many `Float` math trait methods |
| Hash/equality | `equals`, `hash`, `hash_combine` |
| Sized conversions | `to_int8`, `to_int16`, `to_int32`, `to_int128`, `to_uint8`, `to_uint16`, `to_uint32`, `to_uint64`, `to_uint128`, `to_float32`, `to_float16` |
| Bitwise | `bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`, `shift_right` |
| Checked arithmetic | `checked_div`, `checked_mod` |
| Tensor/array helpers | `vector`, `matrix`, `tensor3`, `tensor4`, `tensor5`, `assert_shape`, `checked_get`, `checked_set`, `checked_slice` |
| Concurrency/channel | `sleep`, `sleep_for`, `yield_now`, `max_threads`, `Channel`, `channel`, `send`, `wait_send`, `recv`, `wait_recv`, `try_send`, `try_send_attempt`, `try_recv`, `try_recv_attempt`, `send_timeout`, `send_timeout_attempt`, `send_timeout_attempt_for`, `recv_timeout`, `recv_timeout_attempt`, `recv_timeout_attempt_for`, `seal`, `ConcurrencyError`, `TaskResult`, `ChannelSealed`, `SendAttempt`, `RecvAttempt` |

Most system APIs require explicit imports. Examples:

```blorp
import:
    system: read_file, write_file, file_exists, getenv
    process: run, shell
    debug: debug_string, type_name, is_heap
```

### Process Helpers

`std/process` is explicit-import only:

```blorp
import:
    process as P: exit_code, stdout

func show_git_version() -> Int:
    match P.run("git", ["--version"]):
        Ok(out):
            print(out.stdout())
            out.exit_code()
        Err(msg):
            print(msg)
            1
```

Use `run(program, args)` when arguments come from users or data. `shell(command)`
passes a single string to `/bin/sh -c`; reserve it for fixed developer scripts
or examples where shell syntax is the point.

Operations like `get`, `append`, `sort`, `filter`, `map`, `split`, `trim`,
`substring`, `starts_with`, and `upper` are available as UFCS methods on
prelude types without imports. The bare-name form still requires importing the
function from its module:

```blorp
xs: List[Int] = [3, 1, 2]
sorted: List[Int] = xs.sort()        -- OK without import

import:
    list: sort

same: List[Int] = sort(xs)           -- Bare name needs import
```

### std/string (Additional String Functions)

String is a **prelude type** — all methods work via UFCS with no import needed:

```blorp
-- No import required. Use method syntax:
func string_methods() -> Bool:
    s: String = "hello, world"
    parts: List[String] = s.split(", ")
    trimmed: String = s.trim()
    upper: String = s.upper()
    starts: Bool = s.starts_with("http")
    lines: List[String] = s.lines()
    words: List[String] = s.words()
    padded: String = s.pad_left(10, ' ')
    decoded: String = s.url_decode()
    True
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `drop_left` | `(s: String, n: Int) -> String` | Remove first n characters |
| `take_left` | `(s: String, n: Int) -> String` | Keep first n characters |
| `trim_left` | `(s: String) -> String` | Trim leading whitespace |
| `trim_right` | `(s: String) -> String` | Trim trailing whitespace |
| `count` | `(s: String, sub: String) -> Int` | Count occurrences |
| `lines` | `(s: String) -> List[String]` | Split on newlines |
| `words` | `(s: String) -> List[String]` | Split on whitespace |
| `reverse` | `(s: String) -> String` | Reverse bytes |
| `pad_left` | `(s: String, width: Int, fill: Char) -> String` | Left-pad to width |
| `pad_right` | `(s: String, width: Int, fill: Char) -> String` | Right-pad to width |
| `remove_prefix` | `(s: String, prefix: String) -> String` | Remove prefix if present |
| `remove_suffix` | `(s: String, suffix: String) -> String` | Remove suffix if present |
| `is_alpha` | `(c: Char) -> Bool` | Alphabetic character? |
| `is_digit` | `(c: Char) -> Bool` | Digit character? |
| `is_whitespace` | `(c: Char) -> Bool` | Whitespace character? |
| `is_alphanumeric` | `(c: Char) -> Bool` | Alphanumeric character? |
| `base64_encode` | `(s: String) -> String` | RFC 4648 Base64 encode |
| `base64_decode` | `(s: String) -> Option[String]` | RFC 4648 Base64 decode |
| `url_encode` | `(s: String) -> String` | URL percent-encoding |
| `url_decode` | `(s: String) -> Option[String]` | URL percent-decoding |
| `html_escape` | `(s: String) -> String` | Escape HTML entities |
| `to_bytes` | `(s: String) -> Bytes` | Encode as UTF-8 bytes |

### std/bytes

`Bytes` is an immutable, COW-optimized buffer of unsigned bytes (0-255). Most
operations use UFCS via method syntax. `Bytes` itself is in the prelude, but the
free functions (`from_hex`, `encode_utf8`, `decode_utf8`, `concat`) and the
factory require an import.

```blorp
import:
    bytes as B: Bytes, from_hex, encode_utf8, decode_utf8, concat
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `bytes` | `(size: Int) -> Bytes` | Zero-filled buffer |
| `length` | `(b: Bytes) -> Int` | Buffer length (also via `HasLength`) |
| `is_empty` | `(b: Bytes) -> Bool` | True iff `length == 0` |
| `to_string` | `(b: Bytes) -> String` | Interpret bytes as UTF-8 |
| `get` | `(b: Bytes, i: Int) -> Option[Int]` | Bounds-checked read (0-255) |
| `set_index` | `(b: Bytes, i: Int, v: Int) -> Bytes` | COW write, value clamped 0-255 |
| `slice` | `(b: Bytes, start: Int, len: Int) -> Bytes` | Sub-buffer |
| `append` | `(a: Bytes, b: Bytes) -> Bytes` | Concatenate two buffers |
| `concat` | `(parts: List[Bytes]) -> Bytes` | Concatenate a list of buffers |
| `fill` | `(b: Bytes, v: Int) -> Bytes` | COW fill with value |
| `blit` | `(dst, dst_off, src, src_off, len) -> Bytes` | Bulk memcpy with single COW |
| `index_of` | `(b: Bytes, v: Int, start: Int) -> Option[Int]` | First occurrence |
| `to_hex` | `(b: Bytes) -> String` | Hex-string encoding |
| `from_hex` | `(s: String) -> Option[Bytes]` | Hex-string decoding |
| `encode_utf8` | `(chars: List[Char]) -> Bytes` | Codepoints → UTF-8 |
| `decode_utf8` | `(b: Bytes) -> Option[List[Char]]` | UTF-8 → codepoints |

**Binary encoding** (big- and little-endian 16/32-bit integers):

| Function | Signature |
|----------|-----------|
| `write_int16_be`, `write_int16_le` | `(b: Bytes, offset: Int, v: Int) -> Bytes` |
| `read_int16_be`, `read_int16_le` | `(b: Bytes, offset: Int) -> Option[Int]` |
| `write_int32_be`, `write_int32_le` | `(b: Bytes, offset: Int, v: Int) -> Bytes` |
| `read_int32_be`, `read_int32_le` | `(b: Bytes, offset: Int) -> Option[Int]` |

### std/option

Option is a **prelude type** — all methods work via UFCS with no import needed:

```blorp
-- No import required. Use method syntax:
func option_methods() -> Bool:
    opt: Option[Int] = Some(1)
    value: Int = opt.get_or(0)
    mapped: Option[Int] = opt.map(func(x): x + 1)
    chained: Option[Int] = opt.and_then(func(x): Some(x + 1))
    present: Bool = opt.is_some()
    absent: Bool = opt.is_none()
    True
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `is_some` | `(opt: Option[T]) -> Bool` | Check if Some |
| `is_none` | `(opt: Option[T]) -> Bool` | Check if None |
| `get_or` | `(opt: Option[T], default: T) -> T` | Get value or default |
| `get_or_else` | `(opt: Option[T], f: () -> T) -> T` | Get value or call thunk (pure and impure variants) |
| `map` | `(opt: Option[T], f: (T) -> U) -> Option[U]` | Transform value |
| `filter` | `(opt: Option[T], pred: (T) -> Bool) -> Option[T]` | Keep Some only if predicate holds |
| `and_then` | `(opt: Option[T], f: (T) -> Option[U]) -> Option[U]` | Chain operations |
| `to_result` | `(opt: Option[T], err: E) -> Result[T, E]` | Promote to Result |

### std/result

Result is a **prelude type** — all methods work via UFCS with no import needed:

```blorp
-- No import required. Use method syntax:
func result_methods() -> Bool:
    r: Result[Int, String] = Ok(1)
    value: Int = r.get_or(0)
    mapped: Result[Int, String] = r.map(func(x): x + 1)
    mapped_err: Result[Int, String] = r.map_err(func(e): e + "!")
    chained: Result[Int, String] = r.and_then(func(x): Ok(x + 1))
    ok: Bool = r.is_ok()
    err: Bool = r.is_err()
    True
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `is_ok` | `(r: Result[T, E]) -> Bool` | Check if Ok |
| `is_err` | `(r: Result[T, E]) -> Bool` | Check if Err |
| `get_or` | `(r: Result[T, E], default: T) -> T` | Get value or default |
| `get_or_else` | `(r: Result[T, E], f: (E) -> T) -> T` | Get value or compute from error (pure and impure variants) |
| `map` | `(r: Result[T, E], f: (T) -> U) -> Result[U, E]` | Transform Ok value |
| `map_err` | `(r: Result[T, E], f: (E) -> F) -> Result[T, F]` | Transform Err value |
| `and_then` | `(r: Result[T, E], f: (T) -> Result[U, E]) -> Result[U, E]` | Chain operations |
| `from_option` | `(opt: Option[T], err: E) -> Result[T, E]` | Promote Option to Result |
| `to_option` | `(r: Result[T, E]) -> Option[T]` | Drop Err into None |
| `swap` | `(r: Result[T, E]) -> Result[E, T]` | Swap Ok and Err |

### std/list

List is a **prelude type** — all methods work via UFCS with no import needed:

```blorp
-- No import required. Use method syntax:
func list_methods() -> Bool:
    items: List[Int] = [3, 1, 2]
    doubled: List[Int] = items.map(func(x): x * 2)
    positive: List[Int] = items.filter(func(x): x > 0)
    sorted: List[Int] = items.sort()
    reversed: List[Int] = items.reverse()
    first: Option[Int] = items.get(0)
    appended: List[Int] = items.append(42)
    total: Int = items.fold_left(0, func(acc, x): acc + x)
    len: Int = items.length()
    True
```

Key functions:

| Function | Signature | Description |
|----------|-----------|-------------|
| `head` | `(list: List[T]) -> Option[T]` | First element |
| `tail` | `(list: List[T]) -> List[T]` | All but first |
| `map` | `(list: List[T], f: (T) -> U) -> List[U]` | Transform elements |
| `filter` | `(list: List[T], pred: (T) -> Bool) -> List[T]` | Keep matching |
| `fold_left` | `(list: List[T], init: U, f: (U, T) -> U) -> U` | Left fold (reduce) |
| `fold_right` | `(list: List[T], init: U, f: (T, U) -> U) -> U` | Right fold |
| `flat_map` | `(list: List[T], f: (T) -> List[U]) -> List[U]` | Map and flatten |
| `zip` | `(a: List[A], b: List[B]) -> List[(A, B)]` | Zip into pairs |
| `range` | `(start: Int, end: Int) -> List[Int]` | Integer range |
| `enumerate` | `(list: List[T]) -> List[(Int, T)]` | Add indices |
| `find` | `(list: List[T], pred: (T) -> Bool) -> Option[T]` | First matching |
| `sort_by` | `(list: List[T], key: (T) -> K) -> List[T]` | Sort by key (Int, Float, or String) |
| `concurrent` | `(list: List[T], limit: Int, f: (T) -> U) -> List[Result[U, ConcurrencyError]]` | Concurrent map with explicit fan-out limit |
| `concurrent_with_timeout` | `(list: List[T], limit: Int, timeout: Duration, f: (T) -> U) -> List[Result[U, ConcurrencyError]]` | Concurrent map with a whole-operation timeout |
| `parallel` | `(list: List[T], body: pure (ParallelList[T]) -> ParallelList[U]) -> List[U]` | Parallel list pipeline |
| `unique` | `(list: List[T]) -> List[T]` | Remove duplicates |
| `windows` | `(list: List[T], size: Int) -> List[List[T]]` | Sliding windows |
| `chunks` | `(list: List[T], size: Int) -> List[List[T]]` | Split into chunks |
| `scan` | `(list: List[T], init: U, f: (U, T) -> U) -> List[U]` | Running fold |

All list functions support method-chaining via UFCS:

```blorp
func stringify_items(items: List[Int]) -> List[String]:
    items
        .filter(func(x): x > 0)
        .map(func(x): x * 2)
        .sort_by(func(x): x)
        .map(func(x): to_string(x))
```

List parallelism uses a scoped `ParallelList[T]` view. The view only exposes
parallel-safe combinators (`map`, `filter`, and `filter_map`); it does not
support indexing, mutation, `length`, or conversion back to `List`.

```blorp
pure func double_evens(items: List[Int]) -> List[Int]:
    items.parallel(
        pure func(chunk: ParallelList[Int]):
            chunk
                .filter(pure func(x): x % 2 == 0)
                .map(pure func(x): x * 2)
    )
```

### std/dict

Dict is a **prelude type** — methods work via UFCS with no import. Use `dict as D` for factory functions:

```blorp
import:
    dict as D              -- For D.dict(), D.with_capacity(), D.from_list()

func dict_methods() -> Bool:
    var d: Dict[String, Int] = D.dict()
    reserved: Dict[String, Int] = D.with_capacity(128)
    d = d.set("key", 42)      -- .set() via UFCS, no import needed
    value: Option[Int] = d.get("key")
    keys: List[String] = d.keys()
    True
```

| Function | Signature | Description |
|----------|-----------|-------------|
| `group_by` | `(list: List[T], key: (T) -> K) -> Dict[K, List[T]]` | Group items by key |
| `count_by` | `(list: List[T], key: (T) -> K) -> Dict[K, Int]` | Count items per key |
| `aggregate_by` | `(list: List[T], key: (T) -> K, init: V, f: (V, T) -> V) -> Dict[K, V]` | Aggregate per key |
| `map_values` | `(dict: Dict[K, V], f: (V) -> U) -> Dict[K, U]` | Transform values |
| `filter` | `(dict: Dict[K, V], pred: (K, V) -> Bool) -> Dict[K, V]` | Keep matching |
| `from_list` | `(pairs: List[(K, V)]) -> Dict[K, V]` | Build from key-value pairs |
| `with_capacity` | `(capacity: Int) -> Dict[K, V]` | Create an empty dict with room reserved for expected entries |

### std/int and std/math

`std/int` provides fallible arithmetic and integer-theoretic helpers.
Element-wise scalar math (`sqrt`, `exp`, `log`, `sin`, `cos`, `tan`, `pow`,
`abs`, etc.) is in the prelude via the `FloatingPoint`/`Absolute` traits and
does **not** require this module. `std/math` contains constants such as `PI`,
`E`, and `TAU`, plus cross-type helpers that have not moved to their type
modules yet.

```blorp
import:
    int:
        divide_checked, mod_checked,
        add_checked, subtract_checked, multiply_checked,
        add_saturating, subtract_saturating, multiply_saturating,
        clamp, sign, is_even, is_odd, gcd, lcm, factorial,
        is_power_of_two, next_power_of_two, max_int, min_int
    math:
        MathError(DivByZero, Overflow, Underflow),
        divide_checked_float
```

| Category | Functions |
|----------|-----------|
| Checked | `add_checked`, `subtract_checked`, `multiply_checked`, `divide_checked`, `mod_checked` — return `Result[Int, MathError]` |
| Saturating | `add_saturating`, `subtract_saturating`, `multiply_saturating` — clamp at `INT_MAX`/`INT_MIN` |
| Integer theory | `gcd`, `lcm`, `factorial`, `sign`, `is_even`, `is_odd`, `is_power_of_two`, `next_power_of_two` |
| Bounds | `clamp`, `max_int`, `min_int` |

### std/json

Single-file module: the `JsonValue` union, structured `JsonError` parse
errors, scanner-backed `parse_json_detailed` / `parse_json` entry points, a
`parse` compatibility adapter that preserves remaining input, and an
escape-aware `Stringable` implementation. For
format-agnostic decoding pipelines (JSON + TOML + YAML + CSV composed under
one decoder), use `std/codec` and bridge with
`std/codec_bridge.json_to_value` / `value_to_json`.

```blorp
import:
    json:
        JsonError,
        JsonValue(JsonNull, JsonString, JsonNumber, JsonObject, JsonVector),
        as_string,
        format_error,
        get_field,
        parse_json_detailed,

func main(args: List[String]) -> Int:
    -- Build + serialize
    v: JsonValue = JsonObject([("sub", JsonString("user")), ("iat", JsonNumber(0.0))])
    s: String = v.to_string()

    -- Parse + accessors
    match parse_json_detailed("{\"name\": \"Ada\"}"):
        Ok(jv):
            match get_field(jv, "name"):
                Some(field):
                    match as_string(field):
                        Some(name): print(name)
                        None: print("name is not a string")
                None: print("missing name")
        Err(err): print(format_error(err))

    print(s)
    0
```

`JsonValue` variants: `JsonNull`, `JsonBool(Bool)`, `JsonNumber(Float)`
(integers and floats collapse), `JsonString(String)`, `JsonVector(List)`,
`JsonObject(List[(String, JsonValue)])`.

Key functions: `parse_json_detailed`, `parse_json`, `parse`, `format_error`,
`is_null`, `as_bool`, `as_number`, `as_string`, `as_array`, `as_object`,
`get_field`, and `Stringable.to_string` (the encoder). Because
`Stringable.to_string` is infallible, user-constructed
non-finite `JsonNumber` values (`NaN` or infinity) serialize as `null`; parsed
JSON never produces those values.

For new application code, prefer `parse_json_detailed`, which returns
`Result[JsonValue, JsonError]`, rejects trailing non-whitespace input with
structured line/column context, enforces the JSON number grammar, decodes
standard string escapes and `\uXXXX` escapes, and rejects duplicate object keys.
It uses an indexed scanner for strict whole-input parsing. `parse_json`
preserves the older `Result[JsonValue, String]` surface by formatting
`JsonError`. The lower-level `parse` returns
`parser.ParseResult[JsonValue]` from the same scanner and is mainly useful when
composing parser-like flows because it preserves the remaining input.

### std/codec

Universal serialization framework. Define one decoder, use it with JSON, YAML, TOML, or CSV.

**Value type** — the universal intermediate representation:

```blorp
union Value:
    VNull
    VBool(Bool)
    VInt(Int)
    VFloat(Float)
    VString(String)
    VList(List[Value])
    VRecord(List[(String, Value)])
```

**Decoder combinators** — compose type-safe decoders from primitives:

```blorp
import:
    codec: Decoder, d_string, d_int, field, optional, map3, decode

record Person {name: String, age: Int, email: Option[String]}

pure func make_person(n: String, a: Int, e: Option[String]) -> Person:
    {name = n, age = a, email = e}

-- Write once, use with any format
person_decoder: Decoder[Person] = map3(
    make_person,
    field("name", d_string),
    field("age", d_int),
    optional("email", d_string)
)
```

Primitive decoders: `d_string`, `d_int` (coerces VFloat/VString), `d_float`, `d_bool`.
Combinators: `field`, `optional`, `d_list`, `map2`-`map6`, `d_or_else`, `d_with_default`, `at`, `index`, `d_nullable`, `d_lazy`.

**Encodable trait** for the encode direction:

```blorp
trait Encodable:
    pure func to_value(self: Self) -> Value
```

### std/yaml

Pure blorp YAML parser and encoder. It targets a strict practical subset and
parses directly to `codec.Value`:

```blorp
import:
    yaml as Y

func yaml_parses() -> Bool:
    match Y.parse("name: Alice\nage: 30"):
        Ok(_): True
        Err(_): False
```

Supports plain/quoted scalars, block/flow sequences and mappings, comments, and
YAML 1.2-style auto-classification (`true`/`false` are booleans;
`yes`/`no`/`on`/`off` are strings). Anchors, aliases, tags, directives,
multi-document streams, literal/folded block scalars, and unknown double-quoted
escape sequences return errors. Block sequence items may place a nested mapping
or sequence on the following indented line. Malformed flow collections such as
`[1,]` and `[1,,2]` are rejected instead of producing empty/null items.
`parse(encode(v))` round-trips supported scalar, list, and record `codec.Value`
shapes; source formatting is normalized by `encode(parse(x))`. No external
dependencies.

### std/toml

TOML support parses a strict subset of TOML v1.0 into `TomlValue`: key-value
lines, `[table]` headers, arrays, inline tables, booleans, integers, floats,
basic strings, literal strings, and comments. Unsupported syntax returns
`TomlError` with line/column context from `parse_detailed`, or a formatted
string from the compatibility `parse` wrapper, instead of being guessed as a
string. Table sections and dotted keys are stored as flat keys such as
`"server.port"`. Dates/times, multi-line strings, numeric separators,
non-finite floats, quoted keys, and unicode escapes are rejected in the current
subset. Repeated table headers are rejected.

```blorp
import:
    toml as T

func read_port(input: String) -> Result[Int, String]:
    match T.parse_detailed(input):
        Ok(doc):
            match T.get_int(doc, "server.port"):
                Some(port): Ok(port)
                None: Err("missing server.port")
        Err(err): Err(T.format_parse_error(err))
```

Use typed decoders such as `T.required`, `T.optional`, and `T.map2` when
semantic validation matters. `T.from_string(decoder, input)` runs parsing plus
decoding and returns `String` errors rendered from `TomlDecodeError`.
`TomlError` is for syntax/parser failures; `TomlDecodeError` is for typed
decoder failures after parsing succeeds.

### std/xml

XML parsing returns a small `XmlNode` tree plus structured `XmlError` parse
errors from `parse_detailed`, or formatted string errors from the compatibility
`parse` wrapper. It is a strict simple-element parser, not a full XML 1.0
implementation. Parse errors include line/column context:

```blorp
import:
    xml as X

func root_text(input: String) -> Result[String, String]:
    match X.parse_detailed(input):
        Ok(node): Ok(X.get_text(node))
        Err(err): Err(X.format_error(err))
```

The parser supports elements, quoted attributes, text content, entity
unescaping, comments, and self-closing tags. It rejects trailing input,
mismatched closing tags, malformed attributes, unterminated tags/comments, and
unsupported declarations such as namespaces, CDATA, processing instructions, and
DTD. Nested comments and internal `--` inside comment bodies are rejected.
Invalid tag and attribute names are rejected. Unknown entities are rejected;
supported entities are `&lt;`, `&gt;`, `&amp;`, `&quot;`, and `&apos;`.
Character-by-character scanner loops use indexed `String.get` helpers rather
than one-character substring extraction.

### Parse and Validation Error Conventions

Parsers should return explicit values rather than panic or throw. Use these
conventions when choosing APIs:

- Format modules should expose a `Result` API for application code. Current
  parse surfaces are `json.parse_json_detailed(...) -> Result[JsonValue, JsonError]`
  with `json.parse_json(...) -> Result[JsonValue, String]` as a compatibility wrapper,
  `toml.parse_detailed(...) -> Result[TomlValue, TomlError]` with
  `toml.parse(...) -> Result[TomlValue, String]` as a compatibility wrapper,
  `xml.parse_detailed(...) -> Result[XmlNode, XmlError]` with
  `xml.parse(...) -> Result[XmlNode, String]` as a compatibility wrapper, and
  `yaml.parse(...) -> Result[codec.Value, YamlError]`.
- Prefer module aliases for overlapping names such as `parse` and
  `format_error`: `json as J`, `toml as T`, `yaml as Y`, `xml as X`.
- Plain `String` error payloads are already user-facing text. Structured errors
  should stay structured until the boundary: `json.JsonError` via
  `json.format_error`, `toml.TomlError` via `toml.format_parse_error`,
  `xml.XmlError` via `xml.format_error`, `yaml.YamlError` via
  `yaml.format_error`, `toml.TomlDecodeError` via `toml.format_error`,
  `codec.DecodeError` via `codec.format_error`, and `validation.Invalid` via
  `validation.format_error`.
- Low-level parser combinators use
  `parser.ParseResult[T] = Success(T, remaining) | Failure(message, remaining)`.
  Use them when building parsers or when you need the unconsumed suffix; prefer
  the format module's `Result` wrapper for application code.
- Validation should accumulate domain failures in `validation.Invalid` instead
  of flattening them early. Use `validation.and_validate` to bridge a
  `Result[T, String]` parse/coercion step into validation checks.
- `validation.Check[A, E]` and
  `validation.Validator[Input, Success, Error]` describe the generic validation
  shapes. The default `Invalid`-based layer uses `InvalidCheck[A]` for typed
  checks and `ValueValidator[T]` for `codec.Value -> T` validation. Use
  `map_validator`, `and_then_validator`, `or_else_validator`,
  `one_of_validator`, `succeed_validator`, and `fail_validator` to compose
  validators. Use `string_validator`, `int_validator`, `bool_validator`,
  `float_validator`, `strict_float_validator`, `value_validator`,
  `null_validator`, `field`, `optional_field`, `list_of`, and `object2` through
  `object8` when validating deserialized `codec.Value` data into concrete
  values. `float_validator` accepts `VInt` by coercing it to `Float`;
  `strict_float_validator` accepts only `VFloat`.

Example: validate a deserialized value into an application record.

```blorp
import:
    codec: Value(VInt, VNull, VRecord, VString)
    option: Option
    validation as V:
        ValueValidator,
        field,
        int_validator,
        non_empty,
        object3,
        optional_field,
        positive,
        string_validator,

record User {name: String, age: Int, email: Option[String]}

pure func build_user(name: String, age: Int, email: Option[String]) -> User:
    {name = name, age = age, email = email}

user_validator: V.ValueValidator[User] = V.object3(
    V.field("name", V.string_validator([V.non_empty])),
    V.field("age", V.int_validator([V.positive])),
    V.optional_field("email", V.string_validator([V.non_empty])),
    build_user,
)

input: Value = VRecord([
    ("name", VString("Ada")),
    ("age", VInt(36)),
    ("email", VNull),
])
```

- Error text should describe what failed in user terms. When an API has
  structured error data, render it at the boundary instead of discarding it
  early.

---

## 13. Testing and Doctests

### TestSuite

```blorp
import:
    test: TestSuite

func test_addition() -> Bool:
    1 + 1 == 2

func test_string_concat() -> Bool:
    "hello" + " world" == "hello world"

tests: TestSuite = {
    description = "My Tests",
    tests = [
        ("addition works", test_addition),
        ("string concat", test_string_concat)
    ]
}
```

Run with:

```bash
./blorp test tests/test_blorp/collections/test_list_fundamentals.brp    # Single file
./blorp test tests/test_blorp/                        # All in directory
./blorp test --profile tests/test_blorp/functions/    # With timing
./blorp test --timeout 0 tests/test_blorp/            # Disable test timeout
./blorp test --repeat 50 tests/test_blorp/concurrency/ # Stress-repeat tests
```

`blorp test` defaults to a 30-second timeout per generated test executable. Use
`--timeout N` to change it or `--timeout 0` to disable it. Without an explicit
flag, `BLORP_TEST_TIMEOUT` overrides the test default and `BLORP_TIMEOUT`
serves as the generic fallback.

Use `--repeat N` for stress and flake hunting. Repeated runs disable test result
caching for that invocation so side effects, scheduling, leak checks, and
timeouts are exercised on every pass.

### Doctests

Functions can have docstrings with embedded tests using `---` fenced blocks.

**Named tests with `::`**

Each test has a descriptive name. The test body is a sequence of statements where the last expression must evaluate to `True`:

```blorp
---
Get element at index, returning Option[T].

doctests:
    :: Get element in bounds
    nums: List[Int] = [10, 20, 30]
    match nums.get(1):
        Some(v): v == 20
        None: False

    :: Get element out of bounds returns None
    nums: List[Int] = [10, 20, 30]
    match nums.get(5):
        Some(_): False
        None: True
---
pure func get[T](self: List[T], index: Int) -> Option[T]:
    builtin
```

The `::` format supports multi-line setup, variable bindings, and pattern matching.

Doctests run in a generated test harness. That harness imports the documented
module and the imports already available to that module, so examples can use the
same unqualified helper types and constructors as nearby source. A doctest can
also start with its own `import:` block to add test-only imports; those imports
exist only in the generated doctest harness and are not part of the compiled
library/module artifact.

Run doctests:

```bash
./blorp test --doc std/string.brp       # Run doctests in a single file
./blorp test --doc std/net/             # Run doctests in a directory
```

### Test Organization

```
tests/
  test_blorp/           # Runtime tests (TestSuite-based)
    types/            # Type-specific tests
    functions/        # Function tests
    core/             # Core functionality
    memory/           # Memory leak detection
    concurrency/      # Thread/channel tests
  test_compiler/      # Compiler behavior tests
    parser/           # Parser tests
      should_pass/    # Files that should parse successfully
      should_fail/    # Files that should fail to parse
    infer/            # Type inference tests
      should_pass/
      should_fail/
    typecheck/        # Type checking tests
      should_pass/
      should_fail/
```

---

## 14. CLI Reference

### Commands

| Command | Description |
|---------|-------------|
| `./blorp check <path>` | Parse, import, and type check a file or directory |
| `./blorp compile <file>` | Compile .brp to generated C |
| `./blorp compile --ast <file>` | Print AST |
| `./blorp run <file>` | Compile and run |
| `./blorp run --release <file>` | Compile and run with optimized generated C |
| `./blorp run <file> -- args...` | Run with CLI arguments |
| `./blorp test <path>` | Run test file or directory |
| `./blorp test --doc <path>` | Run only doctests |
| `./blorp test --suite <path>` | Run only TestSuite tests |
| `./blorp format <file>` | Format source file in place |
| `./blorp format --check <file>` | Check formatting (for CI) |
| `./blorp lsp` | Start LSP server (editor integration) |
| `./blorp repl` | Start the interactive REPL |
| `./blorp purify <file>` | Automatically mark pure functions |

### Flags

| Flag | Commands | Description |
|------|----------|-------------|
| `--check` | format | Check formatting without modifying |
| `--ast` | compile | Print AST and exit |
| `--dump-ast`, `--dump-typed-ast` | check, compile | Print AST summaries |
| `--dump-core-after`, `--stop-after` | compile | Inspect Core pipeline stages |
| `--time-phases` | compile | Print compiler phase wall-clock timings |
| `--debug` | compile, run, test, repl | Enable debug mode |
| `--profile` | run, test | Show timing information |
| `--release` | run | Compile generated C with `-O2`; default `run` uses `-O0` for fast edit-run cycles |
| `--threads N` | run | Set max thread pool size |
| `--timeout N` | run, test | Kill after N seconds (`test` defaults to 30; `0` disables) |
| `--sanitize` | run, test | Enable AddressSanitizer + UBSan |
| `--doc` | test | Run only doctests |
| `--suite` | test | Run only TestSuite tests |
| `-j N` | test | Run tests with N parallel workers |
| `--repeat N` | test | Run selected tests N times with result caching disabled |
| `--leak-check` | run, test | Report leaked objects on exit |
| `--no-format` | check, compile, run, test | Skip auto-formatting before command execution |
| `--no-embed-runtime` | compile | Emit generated C for an externally linked runtime |
| `--std-dir <d>` | check, compile, run, test | Use a filesystem std directory |
| `--no-cache` | test | Disable test result caching |
| `-o out.c` | compile | Write generated C to a specific output file |

### Annotations

| Annotation | Applies to | Description |
|------------|-----------|-------------|
| `@tail_recursive` | Functions | Enable tail call optimization |
| `@debug_only` | Functions | Restrict calls/references to `debug:` blocks, `--debug` builds, and `blorp test` |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `BLORP_STD=path` | Use a filesystem standard library directory; overrides `blorp.toml`, and is overridden by `--std-dir` |
| `BLORP_LEAK_CHECK=1` | Enable leak reporting on exit |
| `BLORP_TIMEOUT=N` | Default run/test timeout in seconds (CLI flag overrides; `BLORP_TEST_TIMEOUT` wins for tests) |
| `BLORP_TEST_TIMEOUT=N` | Default `blorp test` timeout in seconds (`--timeout` overrides) |
| `BLORP_FIBER_STACK_SIZE=N` | Fiber stack size in bytes (default 57344 / 56KB) |
| `BLORP_FIBER_STACK_CACHE_BYTES=N` | Maximum bytes of dead fiber coroutine/stack regions to cache for reuse (default 134217728; `0` disables) |
| `BLORP_FIBER_OBJECT_CACHE_COUNT=N` | Maximum dead fiber handle objects to cache for reuse (default 4096; `0` disables) |
| `BLORP_THREADS=N` | Runtime worker thread pool size; `./blorp run --threads N` sets this for the launched program |
| `BLORP_SANITIZE=1` | Enable sanitizers (CLI flag overrides) |
| `BLORP_TLS_BACKEND=unsupported/openssl` | Select the runtime TLS backend profile. `unsupported` is the portable default; `openssl` builds and links the native OpenSSL backend. |
| `BLORP_OPENSSL_CFLAGS` | Compiler arguments for the OpenSSL TLS backend; if unset, `pkg-config --cflags openssl` is used. |
| `BLORP_OPENSSL_LIBS` | Linker arguments for the OpenSSL TLS backend; if unset, `pkg-config --libs openssl` is used. |
| `BLORP_NO_FORMAT=1` | Skip auto-formatting before command execution |

### Project Configuration

`blorp` discovers `blorp.toml` by walking up from the input file's directory. If present, `[std].path` can point at a project-local standard library checkout. Relative paths are resolved relative to the config file.

```toml
[std]
path = "std"
```

Standard library selection precedence is: `--std-dir`, `BLORP_STD`, `blorp.toml`, then the embedded standard library. Filesystem `std/` directories are not guessed; use `blorp.toml` for project-local std source.

### Memory Debugging

```bash
# Run with leak checking
BLORP_LEAK_CHECK=1 ./blorp run program.brp

# Run the focused compiler/runtime leak baselines
scripts/test leak

# Run with AddressSanitizer
./blorp test --sanitize tests/test_blorp/memory/

# Memory stats builtins (in blorp code)
reset_mem_stats()          -- Reset allocation counters
stats = get_mem_stats()    -- Snapshot allocations/releases/live objects
                           -- The MemStats snapshot object is not counted.

# Scheduler stats builtins (in blorp code, from instrumentation)
reset_scheduler_stats()    -- Enable and reset scheduler counters
sched = get_scheduler_stats()
                           -- Snapshot task/fiber/timer/run-queue counters
```

---

## 15. Foreign Function Interface (FFI)

blorp compiles to C, so its `foreign:` FFI works with **any language that exports C-compatible symbols** — C, C++, Rust, and more.

`foreign` declarations are for user modules and explicit `pkg/` modules. The
standard library cannot declare `foreign` functions or depend on `pkg/`
modules; std functionality should be written in Blorp source or exposed through
compiler/runtime `builtin` primitives.

### C

Call C functions directly with `foreign:` blocks:

```blorp
-- A single function still lives inside a foreign block.
foreign:
    func c_sqrt(x: Float) -> Float = "sqrt"

-- Blocks group related functions with shared include/link flags.
foreign(include: "math.h", link: "-lm"):
    func c_sin(x: Float) -> Float = "sin"
    func c_cos(x: Float) -> Float = "cos"
    func c_abs(x: Float) -> Float = "fabs"

-- Ptr is an opaque void* for C pointer interop
foreign(include: "stdio.h"):
    func fopen(path: String, mode: String) -> Ptr = "fopen"
    func fclose(handle: Ptr) -> Int = "fclose"
```

`include:` paths are resolved relative to the `.brp` file that declares the
foreign function. This is independent of the shell working directory and works
the same for `run`, `test`, and imported modules. `link:` is for restricted C
compiler/linker flags: `-lNAME`, `-LDIR`, `-IDIR`, `-framework NAME`, and
`-pthread`. Raw object/archive filenames and raw linker escapes such as
`-Wl,...` are rejected. You do not need `link: "-I..."` just to find a header
next to the Blorp source file.

**Auto-conversions:** `String` arguments automatically convert to `char*`. `String` return values automatically wrap into blorp strings. Fixed-size array arguments automatically expand to `(data_ptr, len)` pairs. All other types must match the C signature exactly.

### Safety Modes

Foreign functions have three modes that control argument safety and purity:

```blorp
-- DEFAULT: impure, copies String and Bytes args before passing to C.
-- The C function gets its own copy — cannot corrupt blorp-managed data.
foreign:
    func process(data: String) -> Int = "process_data"

-- PURE: callable from pure blorp code. No copy needed (caller asserts
-- the C function won't mutate arguments or have side effects).
foreign:
    pure func my_sin(x: Float) -> Float = "sin"

-- NO COPY: impure, but skips the defensive copy. Use when the C function
-- treats blorp data as read-only but has other side effects (e.g. logging).
foreign:
    @no_copy func log_data(data: String) -> Void = "log_data"
```

| Declaration | Copies args? | Callable from pure? |
|---|---|---|
| `func` in a `foreign:` block | Yes (COW) | No |
| `pure func` in a `foreign:` block | No | Yes |
| `@no_copy func` in a `foreign:` block | No | No |

**Default (safe):** impure functions in a `foreign:` block copy eligible mutable runtime buffers before passing them to C. Today that covers `String` and `Bytes` arguments. The C function receives its own call-local copy that it can read or write without affecting the original blorp data. Copies are automatically released after the call returns, so C code must not retain or return pointers to those argument copies. Other managed arguments such as lists, dicts, sets, tensors, records, unions, and function values are rejected in default mode until they have explicit defensive-copy support. Scalar by-value arguments, including user enums, are allowed. Use `@no_copy` only when the C function borrows the value without mutating or retaining it.

**Pure:** `pure func` inside a `foreign:` block asserts that the C function is referentially transparent — no side effects, no mutation. This allows it to be called from `pure func` in blorp. No defensive copy is made since pure functions don't mutate. Use this for math functions, hash functions, and other stateless computations.

**No-copy:** `@no_copy` on an impure function inside a `foreign:` block skips the defensive copy for performance. The C function receives direct pointers into blorp-managed memory. Use this only when you're certain the C code treats the data as read-only.

```blorp
-- Pure math functions — no copy, callable from pure code
foreign(include: "math.h"):
    pure func sin(x: Float) -> Float
    pure func cos(x: Float) -> Float
    pure func sqrt(x: Float) -> Float
    pure func log(x: Float) -> Float
```

### C++

C++ classes and functions are called through a thin C wrapper using `extern "C"`:

```cpp
// vec3_wrapper.cpp — expose C++ class through C functions
#include "vec3.hpp"
extern "C" {
    void* vec3_new(double x, double y, double z) { return new Vec3(x, y, z); }
    void  vec3_free(void* v) { delete static_cast<Vec3*>(v); }
    double vec3_dot(void* a, void* b) {
        return static_cast<Vec3*>(a)->dot(*static_cast<Vec3*>(b));
    }
}
```

```blorp
-- Declare the C wrapper functions, link a library plus the C++ stdlib.
foreign(include: "vec3_ffi.h", link: "-Lnative -lvec3_ffi -lstdc++"):
    func vec3_new(x: Float, y: Float, z: Float) -> Ptr
    func vec3_free(v: Ptr) -> Void
    func vec3_dot(a: Ptr, b: Ptr) -> Float
```

C++ objects are passed as `Ptr` (opaque `void*`). Memory is managed manually — call the wrapper's free function when done. Build wrapper objects into a library that the C compiler can find with `-L... -l...`; raw `.o` filenames are rejected by FFI metadata validation.

### Rust

Rust functions are exported with `#[no_mangle] extern "C"`:

```rust
// lib.rs — crate-type = ["staticlib"] in Cargo.toml
#[no_mangle]
pub extern "C" fn rust_gcd(mut a: i64, mut b: i64) -> i64 {
    while b != 0 { let t = b; b = a % b; a = t; }
    a.abs()
}
```

```blorp
-- Link the Rust static library through a library search path.
foreign(include: "blorp_rust_ffi.h", link: "-Ltarget/release -lblorp_rust_ffi -liconv -lSystem"):
    func rust_gcd(a: Int, b: Int) -> Int
```

For string interop, Rust must accept `*const c_char` and return `*mut c_char`. blorp handles the blorp side automatically.

### Summary

| Language | Wrapper Pattern | Link Flags |
|----------|----------------|------------|
| C | None needed | `-lm`, `-lpthread`, etc. |
| C++ | `extern "C"` wrapper functions | `-Lnative -lvec3_ffi -lstdc++` |
| Rust | `#[no_mangle] extern "C"` | `-Ltarget/release -lname -liconv -lSystem` |

---

## 16. Known Limitations For Preview

This section describes current preview boundaries and what users can rely on
today.

- `debug:` blocks and `@debug_only` APIs are for test/debug builds. They are
  available under `--debug` and during `blorp test`; normal builds reject
  debug-only calls outside a `debug:` block.
- There is no source-level breakpoint facility in the preview debug API.
- `foreign:` is the native trust boundary. String and bytes arguments get
  defensive copies in the default mode, but opaque `Ptr` values and no-copy FFI
  declarations rely on the foreign code honoring its contract.
- `pkg/...` imports are explicit package/native boundaries. Bare imports
  resolve local modules or `std`, not packages.
- Parser/format modules such as JSON, TOML, YAML, XML, validation, and parser
  utilities use ordinary `Result` values, but their detailed error payloads are
  still module-specific rather than one shared diagnostics type.
- `Fixed` and some tensor shape helper APIs are preview surfaces. Prefer
  documenting concrete module imports in examples instead of relying on broad
  implicit availability.
- The canonical pure-lambda spelling is `pure func(...)`.

## 17. Editor Support

The `editor/` directory provides IDE/editor extensions backed by shared
TextMate metadata and the `./blorp lsp` language server:

- **VSCode**: `editor/vscode/` — syntax highlighting, language configuration,
  and LSP integration. The extension prefers an executable `./blorp` in the
  workspace root, then falls back to `blorp` on `PATH`.
- **IntelliJ**: `editor/intellij/` — TextMate highlighting plus optional
  platform LSP integration for IntelliJ-based IDEs.

The current editor surface includes keyword/operator highlighting, string
interpolation highlighting, diagnostics, hover, completion, and go-to-definition.
LSP document formatting is intentionally not advertised yet; use
`./blorp format` for source formatting.

---

## 18. Keywords

```
func       pure       var        union      enum       record     struct     trait
type       alias      private    import     as         implements Self       builtin
match      while      for        in         if         else       and        or
not        True       False      void       break      continue   debug      foreign
concurrent concurrently detach   select     from       after      sealed     with
resource   where        into
```
