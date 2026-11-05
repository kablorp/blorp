# Blorp

Blorp is a compiled language for writing safe, understandable code that is easy
to generate, review, debug, and trust. Its compiler is written in Blorp and
emits C.

Blorp is in early preview. For the language tour, examples, and current project
status, start here:

**https://blorp-lang.org**

## Where Blorp lives

The compiler, its standard library, tests and tooling live in
[`blorp_2/`](blorp_2/):

- [`blorp_2/README.md`](blorp_2/README.md) defines the supported language and
  the compiler's design.
- [`blorp_2/grammar.ebnf`](blorp_2/grammar.ebnf) is the formal grammar.
- [`blorp_2/AGENTS.md`](blorp_2/AGENTS.md) holds the build, test and review
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
make -C blorp_2 compiler    # downloads the pinned, SHA-256-verified seed, then builds
make -C blorp_2 example     # compiles and runs a small program through the new compiler
make -C blorp_2 test        # self-hosted component suites and native end-to-end tests
```

The compiler's command line is
`blorp_2/build/compiler --library-root blorp_2/standard_library INPUT.brp OUTPUT.c`;
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
