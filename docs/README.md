# Blorp Documentation

These documents describe the current language, toolchain, and implementation.
Completed implementation history belongs in Git history, pull requests,
benchmark results, and issues rather than in maintained reference documents.

## Learn The Language

- [Learn Blorp in Y Minutes](LEARN_BLORP_IN_Y_MINUTES.md) is the concise tour
  and preferred-pattern guide.
- [Language Guide](GUIDE.md) is the complete source-language reference.
- [Formal Grammar](GRAMMAR.md) is the parser-level EBNF contract.

## Use The Toolchain

- [Lint](LINT.md) documents typed source findings and stable rule IDs.
- [Source Packages](PACKAGES.md) defines portable package layout, hashing,
  caching, and vendoring.
- [Releases](RELEASES.md) defines release channels and binary assets.

For exact command-line options, use `blorp <command> --help`. Standard-library
module inventory lives in [`std/README.md`](../std/README.md).

## Understand The Implementation

- [Compiler Architecture](ARCHITECTURE.md) defines phase ownership, pipeline
  order, and backend boundaries.
- [Memory Model](MEMORY_MODEL.md) explains source-level value semantics, ARC,
  and copy-on-write behavior.
- [Ownership Model](OWNERSHIP_MODEL.md) defines the compiler/runtime ownership
  ABI for managed values.
- [Concurrency And Resources](CONCURRENCY_AND_RESOURCES.md) defines structured
  concurrency, cancellation, resources, streams, and networking contracts.
- [Compiler Priorities](COMPILER_PRIORITIES.md) contains only current
  cross-cutting compiler work and its completion criteria.

## Maintenance Rules

- Reference docs describe current behavior, not migration history.
- Active implementation status, assignees, and discussion belong in GitHub
  issues. Versioned handoff specifications may live under `docs/issues/` when
  they define architectural dependencies, implementation boundaries, and
  durable acceptance criteria; they must not become a second status tracker.
- Put raw performance evidence in `benchmarks/results/` and link it from the
  issue or change that uses it.
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
