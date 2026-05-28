# Blorp

Blorp is a compiled language for writing safe, understandable code that is easy
to generate, review, debug, and trust.

Blorp is in early preview. For the language tour, examples, documentation, and
current project status, start here:

**https://blorp-lang.org**

## Hello, World

```blorp
func main(args: List[String]):
	print("Hello, world!")
```

## Try It Out

The easiest way to try Blorp is to install the latest dev release. This
downloads the matching binary for your system and installs a single binary to `~/.local/bin/blorp`.

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash

~/.local/bin/blorp --version
```

To remove the dev binary:

```bash
rm -f "$HOME/.local/bin/blorp"
```

A C compiler such as clang or gcc is still required to compile and run Blorp
programs.

Building from source is mainly useful for compiler development. To do that,
install OCaml 4.14.x, dune, menhir, and a C compiler such as clang or gcc, then
run:

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
git clone https://github.com/kablorp/blorp.git
cd blorp
make
scripts/test
```

Local builds write the compiler executable to `./blorp` in the repository root.
Use that binary for development commands instead of an installed dev release.

The main test runner is quiet by default and prints a gate summary plus failure
details. Use `scripts/test --verbose` for pass-by-pass output, or
`scripts/test --log-dir logs` to keep complete gate logs while preserving
compact console output.

Useful targeted commands:

```bash
./blorp check path/to/file.brp
./blorp run path/to/file.brp
./blorp test tests/test_blorp/types/test_bool.brp
./blorp format --check path/to/file.brp
```
