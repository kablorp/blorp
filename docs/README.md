# Blorp Docs

Top-level documentation is maintained project knowledge. Git history, issues,
pull requests, benchmark results, and commit messages hold completed
implementation history.

## Learning

- [LEARN_BLORP_IN_Y_MINUTES.md](LEARN_BLORP_IN_Y_MINUTES.md) is the quickest
  tour for new users and agents.
- [GUIDE.md](GUIDE.md) is the full language and standard-library reference.
- [GRAMMAR.md](GRAMMAR.md) is the parser-level EBNF reference.
- [PACKAGES.md](PACKAGES.md) documents portable source-package layout and
  validation.

## Semantics

- [MEMORY_MODEL.md](MEMORY_MODEL.md) explains user-facing value semantics,
  ARC, and copy-on-write behavior.
- [OWNERSHIP_MODEL.md](OWNERSHIP_MODEL.md) defines the compiler/runtime
  ownership ABI for managed values.
- [CONCURRENCY_AND_RESOURCES.md](CONCURRENCY_AND_RESOURCES.md) defines
  structured concurrency, virtual-thread, resource, stream, and networking
  contracts.

## Compiler

- [ARCHITECTURE.md](ARCHITECTURE.md) is the source of truth for compiler
  structure, phase ownership, Core pass order, and backend boundaries.
- [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) contains current cross-cutting
  priorities: migration, generated-program performance, compiler/test
  performance, and semantic cleanup.
- [BLORP_COMPILER_PORT_ROADMAP.md](BLORP_COMPILER_PORT_ROADMAP.md) is the
  detailed execution plan for finishing the OCaml-to-Blorp migration.
- [BLORP_TEST_SESSION_ROADMAP.md](BLORP_TEST_SESSION_ROADMAP.md) is the active,
  temporary execution plan for making `blorp test` Blorp-owned with
  invocation-local frontend and typed-artifact reuse.
- [BLORP_COMPILER_CLEANUP_AUDIT.md](BLORP_COMPILER_CLEANUP_AUDIT.md) records
  reviewed dead-code candidates, migration-specific cleanup, and active
  boundaries that must be retained.
- [STATIC_CONSTANT_EMISSION.md](STATIC_CONSTANT_EMISSION.md) documents the
  current static constant representation and emission boundary.

## Releases

- [RELEASES.md](RELEASES.md) describes release channels and binary assets.

## Maintenance Rules

- Keep reference docs aligned with implementation and tests in the same
  change.
- Keep one concise active roadmap per area. A specialized plan is justified
  only when it has an active owner, distinct completion criteria, and current
  implementation work.
- Delete completed or superseded roadmaps after moving durable contracts into
  reference docs and remaining work into the active roadmap. Git is the
  archive.
- Put raw performance evidence in `benchmarks/results/`; keep only conclusions
  that affect current decisions in roadmaps.
- Link to source files and tests for facts that can drift quickly.
- Do not preserve pre-0.1 compatibility notes unless they explain current
  behavior.
