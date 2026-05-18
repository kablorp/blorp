# Blorp

Blorp is a language for writing safe, fast code that is easy to reason about.
It is built with AI in mind: code should be easy to generate,
review, debug, and _trust_. The purity system, value semantics, and explicit effect
boundaries make hidden behavior harder and program intent clearer.

> Blorp is in early-preview. It is not ready for production usage.

## Hello, world!

```blorp
func main(args: List[String]) -> Void:
	print("Hello, world!")
```
Blorp's syntax is inspired by Python. `main` signifies the entry point
to a program.

## At a Glance
The core shape of Blorp leverages pure functions, explicit data states, pattern matching, and IO at the program boundary.


```blorp
-- Union variants make each possible state explicit
union Score:
    Passing(Int)
    NeedsPractice(Int)

-- Pure functions are encoded in the type system
pure func grade(scores: List[Int]) -> Score:
    -- Any function can be called with method syntax by its first argument:
    -- scores.length() is the same as length(scores)
    average: Int = total(scores) / scores.length()
    if average >= 70:
        Passing(average)
    else:
        NeedsPractice(70 - average)

-- Pure functions can use local mutation.
pure func total(scores: List[Int]) -> Int:
    var sum: Int = 0
    for score in scores:
        sum += score
    sum


-- Pattern matching must cover every variant
pure func describe_score(score: Score) -> String:
    match score:
        Passing(avg): "passing average: ${avg}"
        NeedsPractice(points): "needs ${points} more points"


-- Method syntax allows clear chaining of operations
func main(args: List[String]) -> Void:
    scores = [82, 71, 90]
    
    scores
        .grade()
        .describe_score()
        .print()
```

Other common patterns stay explicit and low ceremony:

```blorp
-- Generics: one implementation works for any element type.
pure func first_or[T](items: List[T], fallback: T) -> T:
    match items.get(0):
        Some(value): value
        None: fallback

-- Trait bounds: operators are available when the type promises the behavior.
pure func larger[T: Orderable](a: T, b: T) -> T:
    if a > b:
        a
    else:
        b

-- try: expressions keep fallible code linear and still return Option/Result.
pure func first_two_total(scores: List[Int]) -> Option[Int]:
    try:
        first ?= scores.get(0)
        second ?= scores.get(1)
        first + second

-- concurrent: scopes parallel work and joins it before continuing.
func compare_totals(left: List[Int], right: List[Int]) -> Result[Int, ConcurrencyError]:
    concurrent:
        left_total = some_io_call(left)
        right_total = another_io_call(right)

    try:
        a ?= left_total
        b ?= right_total
        a - b
```

There's much more in the [Language Guide](docs/GUIDE.md).


## Core Features

| Feature                    | Why it matters                                                                                 |
|----------------------------|------------------------------------------------------------------------------------------------|
| **Readable syntax**        | Indentation, keyword operators, and method-style calls keep data flow easy to scan.            |
| **Static safety**          | Strong types, checked imports, explicit fallibility, and exhaustive matching catch bugs early. |
| **Purity tracking**        | `pure func` separates deterministic logic from I/O while still allowing local mutation.        |
| **Value semantics**        | No shared mutable state; ARC/COW handles efficient sharing without manual memory management.   |
| **Compile-time bounds**    | Tensor dimensions like `Int[#3]` and `Float[#2, #2]` let the compiler prove safe indexing.     |
| **Structured concurrency** | `concurrent:` blocks auto-join spawned work, avoiding orphaned tasks.                          |
| **Native performance**     | Blorp compiles to C with predictable resource management and SIMD-friendly tensors.            |
| **Tool-friendly design**   | Stable formatting and explicit effects make code easier to generate, review, and debug.       |


## Purity

Blorp tracks whether functions are pure or impure. A `pure func` cannot perform
I/O, mutate global state, call impure functions, or accept impure callbacks.
It can still use local variables and loops, because local mutation does not
change the observable behavior of the function.

This provides several advantages:
- Pure functions are easier to test, cache, reorder, parallelize, and reason about.
- Pure callbacks can be safely used by parallel collection operations.
- Side effects are visible at function boundaries.
- Optimization passes can be more aggressive because pure code has fewer
  observable ordering constraints.

For AI-generated code, purity turns a broad trust problem into a smaller review
problem. Large parts of codebases can be made statically unable to do
I/O, mutate global state, or exfiltrate data. As such, some aspects of debugging 
and code review can be confined to narrow code paths where effects are allowed.


## Runtime Safety Model

Blorp is designed so ordinary language operations are safe by construction,
instead of relying on unchecked runtime failures:
- no null values or unchecked exceptions
- absence and fallibility are represented with `Option[T]`, `Result[T, E]`, `match`, and `try:` 
- no shared mutable state
- deterministic ARC/COW memory management
- structured concurrency joins spawned work before the block exits

The compiler is still early, so these principles should not yet be treated as production hardened.


## Compile-Time Bounds Checking

Blorp checks bounds at compile time for vectors, matrices, and higher-dimensional
tensors. This facilitates fast indexed code without compromising safety.

```blorp
-- A vector with exactly three Int values.
scores: Int[#3] = {10, 20, 30}

-- The compiler can prove this access is in bounds.
last: Int = scores[2]

-- A 2 x 2 matrix of Float values.
grid: Float[#2, #2] = {
    {1.0, 2.0},
    {3.0, 4.0}
}

-- Multiple indices can target multiple dimensions.
cell: Float = grid[1, 0]
```


## Performance

Blorp compiles to C, so idiomatic Blorp code is intended to keep predictable
native performance while preserving stronger safety and tooling guarantees.

The benchmark suite lives under `benchmarks/`. Benchmark numbers are
environment-sensitive and should be treated as a recent local snapshot rather
than a production guarantee.

| Benchmark | Blorp | C | Go | Python | vs C | vs Go | vs Python |
|-----------|-------|---|----|--------|------|-------|-----------|
| `numeric_loop` | 0.1090s | 0.1113s | 0.1754s | 5.2666s | 1.0x | 1.6x | 48.3x |
| `fib` | 0.2152s | 0.1862s | 0.2579s | 7.5098s | 0.9x | 1.2x | 34.9x |
| `string` | 0.1065s | 0.1070s | 0.1609s | 0.2018s | 1.0x | 1.5x | 1.9x |
| `array_sum` | 0.0005s | 0.0005s | 0.0039s | 0.0975s | 1.0x | 7.8x | 195.0x |
| `array_ops` | 0.0077s | 0.0044s | 0.0185s | 0.5151s | 0.6x | 2.4x | 66.9x |
| `dict_ops` | 0.1321s | - | 0.1460s | 0.3587s | - | 1.1x | 2.7x |
| `list_ops` | 0.1144s | - | 0.2197s | 0.4325s | - | 1.9x | 3.8x |
| `set_ops` | 0.3137s | - | 0.5540s | 0.2348s | - | 1.8x | 0.7x |
| `options` | 0.0120s | - | - | - | - | - | - |
| `simd` | 0.1146s | 0.1068s | - | - | 0.9x | - | - |
| `nbody` | 0.0476s | 0.0383s | 0.0419s | 3.1165s | 0.8x | 0.9x | 65.5x |
| `binary_trees` | 0.1188s | 0.1349s | 0.1041s | 0.6919s | 1.1x | 0.9x | 5.8x |
| `fannkuch` | 0.2761s | 0.1763s | 0.1539s | 2.6346s | 0.6x | 0.6x | 9.5x |
| `spectral_norm` | 0.0108s | 0.0076s | 0.0162s | 0.9193s | 0.7x | 1.5x | 85.1x |
| `mandelbrot` | 0.0037s | 0.0016s | 0.0286s | 0.0610s | 0.4x | 7.7x | 16.5x |
| `knucleotide` | 0.0201s | - | 0.0248s | 0.0610s | - | 1.2x | 3.0x |
| `reverse_complement` | 0.0001s | - | 0.0001s | 0.0026s | - | 1.0x | 26.0x |

While the benchmarks are not authoritative, they suggest Blorp is often:
- much faster than Python
- faster than garbage-collected languages like Go (or Java)
- within range of C


For current local numbers, run:

```bash
make
./benchmarks/bench.sh
```

See [benchmarks/README.md](benchmarks/README.md) for the timing model, benchmark
inventory, and environment controls.


## What Blorp Leaves Out

Blorp is not a kitchen-sink language. Some features are omitted to
keep programs easier to reason about and make compiler output easier to optimize.
- **No null**: optional values are represented with `Option[T]`.
- **No exceptions**: fallible operations use `Option[T]`, `Result[T, E]`, and
`try:`.
- **No `Any` type**: values keep concrete static types instead of falling back to
  unchecked dynamic containers.
- **No classes**: data and functions are fundamentally separate
- **No manual memory management**: resources are managed through ARC/COW and
  value semantics.
- **No ownership semantics**: Blorp prefers direct value semantics instead.
- **No macros**: code generation and compile-time metaprogramming are outside
  the current language.
- **No `async`/`await`**: concurrency is structured around `concurrent:`,
  channels, and explicit task lifetimes to avoid function coloring issues
- **No variadic function arguments**: function arity is fixed and visible in the
  type. 
- **No higher-kinded types**: generics and traits are intended to cover the 
  common cases without a second type-level language.
- **No algebraic effects**: type-level purity provides a good balance of power / semantic clutter.
- **No currying**: functions take their arguments explicitly.

The goal is these omissions keep the surface lean and the compiler easier to reason about. It's possible
we may add some of them in the future, but the intension is to be conservative in adding new features. 



## Try It Out

### Prerequisites

- **OCaml** 4.14.x with opam
- **dune** (>= 3.3) and **menhir** parser generator
- **C compiler** (clang or gcc)
- macOS or Linux

```bash
# macOS
brew install opam
opam init && opam switch create 4.14.0
opam install ./compiler/blorp.opam --deps-only --with-test

# Ubuntu/Debian
sudo apt install clang opam
opam init && opam switch create 4.14.0
opam install ./compiler/blorp.opam --deps-only --with-test
```

Run some code:

```bash
make
./blorp run examples/hello.brp
```

Useful commands:

```bash
./blorp check program.brp
./blorp check src/
./blorp test tests/test_blorp/
./blorp format file.brp
./blorp repl
```

## Documentation

| Document | Description |
|----------|-------------|
| [Language Guide](docs/GUIDE.md) | Complete language reference |
| [Formal Grammar](docs/GRAMMAR.md) | EBNF grammar |
| [Memory Model](docs/MEMORY_MODEL.md) | ARC, COW, uniqueness |
| [Ownership Model](docs/OWNERSHIP_MODEL.md) | Compiler-facing ownership, Perceus, and COW ABI |
| [Architecture](docs/ARCHITECTURE.md) | Compiler internals |
| [Backend Independence](docs/BACKEND_INDEPENDENCE.md) | Backend-facing Core IR contract |

## Contributing
If you'd like to contribute, the best thing would be to simply try to use the language and file bugs for any issues
you run into. Blorp is not yet ready to receive PR contributions from outside contributors.

## Influences 
Blorp has adopted ideas from many great programming languages, such as:
- Python
- Scala
- Go
- Elm
- Rust
- Roc
- OCaml
- C
- D
- Swift

## Why "Blorp"? 
"Blorp" is the name of a fictional stegosaurus my kids and I made up. He has a Pterodactyl friend
called "Florp". There are other entities with these names, but those ain't this.
