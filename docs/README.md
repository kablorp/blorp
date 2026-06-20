# Blorp Docs

The top-level docs are for current, maintained project knowledge. Avoid adding
long implementation diaries here; use issues, PR descriptions, or commit notes
for history.

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
- [0.1_MEMORY_HARDENING.md](0.1_MEMORY_HARDENING.md) tracks the release-blocking
  memory leak hardening and gate expansion plan.

## Compiler

- [ARCHITECTURE.md](ARCHITECTURE.md) is the source of truth for compiler
  structure, Core pass order, and backend boundaries.
- [COMPILER_ROADMAP.md](COMPILER_ROADMAP.md) tracks active compiler cleanup,
  call-resolution, performance, and native-boundary work.

## Runtime And Resources

- [CONCURRENCY_AND_RESOURCES.md](CONCURRENCY_AND_RESOURCES.md) tracks
  structured concurrency, virtual-thread behavior, scoped resources, streams,
  and networking resource direction.

## Releases

- [RELEASES.md](RELEASES.md) describes release channels and binary assets.

## Maintenance Rules

- Keep reference docs aligned with implementation and tests in the same change.
- Prefer one active roadmap per area. If a roadmap becomes mostly completed
  progress notes, fold remaining decisions into the active roadmap and delete
  the old file.
- Link to source files and tests for details that can drift quickly.
- Do not preserve pre-0.1 compatibility notes unless they help users understand
  the current behavior.
