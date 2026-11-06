# Blorp

Blorp is a compiled language for writing safe, understandable code that is easy
to generate, review, debug, and trust. Its compiler is written in Blorp and
emits C.

Blorp is in early preview. For the language tour, examples, and current project
status, start here:

**https://blorp-lang.org**

## Where Blorp lives

The compiler, its standard library, tests and tooling live in
[`blorp/`](blorp/):

- [`blorp/README.md`](blorp/README.md) defines the supported language and
  the compiler's design.
- [`blorp/grammar.ebnf`](blorp/grammar.ebnf) is the formal grammar.
- [`blorp/AGENTS.md`](blorp/AGENTS.md) holds the build, test and review
  rules for contributors.

The earlier compiler (a larger language with tensors, concurrency, a formatter,
a language server and a package manager) was retired from this tree. It stays
in git history; commit
[`ee9e001c6de8`](https://github.com/kablorp/blorp/tree/ee9e001c6de8911ee486fd992419bef5bc628e8b)
is its last revision.

## Build and test

Install a C compiler such as Clang or GCC, plus `curl`. `BLORP_CC=gcc` selects
GCC instead of the default Clang.

```bash
git clone https://github.com/kablorp/blorp.git
cd blorp
make -C blorp compiler    # downloads the pinned, SHA-256-verified seed, then builds
make -C blorp example     # compiles and runs a small program through the new compiler
make -C blorp test        # self-hosted component suites and native end-to-end tests
```

The compiler's command line is
`blorp/build/compiler --library-root blorp/standard_library INPUT.brp OUTPUT.c`;
compile the C with your C compiler.

`scripts/blorp2-fixpoint --prove` proves that the compiler reproduces its own C
from its own source. `benchmarks/bench.sh` compares Blorp with C, Go, OCaml and
Python on small programs; see [benchmarks/README.md](benchmarks/README.md).

## In Brief

Blorp focuses on:

- Static safety without null, exceptions, or shared mutable state.
- Explicit purity tracking with `pure func`.
- Value semantics with deterministic ARC/COW memory management.
- Pattern matching, algebraic data types, traits, and method-style function calls.
- Native compilation through C.
- Syntax and tooling that are predictable for both humans and code-generation tools.

## License

See [LICENSE](LICENSE).
