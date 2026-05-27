# Blorp

Blorp is a compiled language for writing safe, understandable code that is easy
to generate, review, debug, and trust.

Blorp is in early preview. For the language tour, examples, documentation, and
current project status, start here:

**https://blorp-lang.org**

## Hello, World

```blorp
func main(args: List[String]):
	println("Hello, world!")
```

## Try It Out

Prerequisites: OCaml 4.14.x, dune, menhir, and a C compiler such as clang or
gcc.

```bash
make
./blorp run examples/hello.brp
```

For more examples and setup notes, see https://blorp-lang.org.

## In Brief

Blorp focuses on:

- Static safety without null, exceptions, or shared mutable state.
- Explicit purity tracking with `pure func`.
- Value semantics with deterministic ARC/COW memory management.
- Pattern matching, algebraic data types, traits, and method-style function calls.
- Structured concurrency and native compilation through C.
- Syntax and tooling that are predictable for both humans and code-generation tools.

## Local Development

```bash
make
scripts/run_tests.sh
```

Useful targeted commands:

```bash
./blorp check path/to/file.brp
./blorp run path/to/file.brp
./blorp test tests/test_blorp/types/test_bool.brp
./blorp format --check path/to/file.brp
```

See [AGENTS.md](AGENTS.md) for repository development guidance.
