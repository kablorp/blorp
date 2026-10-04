# Blorp Documentation

Start with the reference for your task. References describe current behavior;
plans describe proposed changes and remaining work, not available features.
Completed work belongs in Git history and benchmark results.

## Learn The Language

- [Learn Blorp in Y Minutes](LEARN_BLORP_IN_Y_MINUTES.md) is the concise tour
  and preferred-pattern guide.
- [Language Guide](GUIDE.md) is the complete source-language reference.
- [Formal Grammar](GRAMMAR.md) is the parser-level EBNF contract.

## Use The Toolchain

- [Worker Checklist](WORKER_CHECKLIST.md) is the one page to read before
  starting a compiler or compiler-performance task: setup, fast feedback
  loop, measurement, and landing rules.
- [Code Shape](CODE_STYLE.md) says what a function takes, when a function or
  binding earns its place, and how long names should be.
- [Developer Guide](DEVELOPMENT.md) is the practical workflow for building,
  testing, diagnosing, profiling, and changing Blorp and its compiler.
- [Lint](LINT.md) documents typed source findings and stable rule IDs.
- [Source Packages](PACKAGES.md) defines portable package layout, hashing,
  caching, and vendoring.
- [Releases](RELEASES.md) defines release channels and binary assets.

For exact command-line options, use `blorp <command> --help`. Standard-library
module inventory lives in
[`standard_library/README.md`](../standard_library/README.md).

## Understand The Implementation

- [Compiler Architecture](ARCHITECTURE.md) defines phase ownership, pipeline
  order, and backend boundaries.
- [Discovery Tables](DISCOVERY_TABLES_DESIGN.md) defines the current front-end
  output, identities, spans, validation, and legacy adapter boundary.
- [Memory Model](MEMORY_MODEL.md) explains source-level value semantics, ARC,
  and copy-on-write behavior.
- [Ownership Model](OWNERSHIP_MODEL.md) defines the compiler/runtime ownership
  ABI for managed values.
- [Concurrency And Resources](CONCURRENCY_AND_RESOURCES.md) defines structured
  concurrency, cancellation, resources, streams, and networking contracts.

## Open Issues And Plans

[`issues/`](issues/) holds reproducible open problems. [Diagnostic Gaps](DIAGNOSTIC_GAPS.md)
owns diagnostic-quality findings and indexes compiler faults; each fault's
issue owns its reproduction and acceptance criteria.

The compiler-speed goal is to emit C for `blorp/src/main.brp` in about ten
seconds, not a claim about current performance. Use the
[self-compile protocol](../benchmarks/README.md#self-compile-measurement-protocol)
for matched measurements; do not copy a profile into the work index.

- [Compiler Speed](COMPILER_SPEED_ROADMAP.md): redundant walks and remaining
  pass-level experiments.
- [Per-Node Codegen](PER_NODE_CODEGEN_ROADMAP.md): ARC, cleanup frames, and
  borrowed traversal in generated code.
- [Identity And Tables](IDENTITY_ROADMAP.md): identity authorities, names to
  IDs, type interning, and remaining table migrations.
- [Record Simplification](FIXED_LAYOUT_ROADMAP.md): ordinary-record semantics,
  ABI boundaries, and later measured placement optimizations.
- [Allocation Contracts](ALLOCATION_CONTRACT_ROADMAP.md): incomplete backend
  coverage and proposed `no_alloc` enforcement. The existing report is
  described in [Architecture](ARCHITECTURE.md#allocation-reports).
- [Discovery Acceptance](DISCOVERY_ACCEPTANCE_ROADMAP.md): parser differences
  and retiring legacy consumers. [Discovery Redesign](DISCOVERY_REDESIGN.md)
  separately proposes typed syntax trees; that path is not implemented.
- [Value Tuples And State Handoff](VALUE_TUPLES_AND_STATE_HANDOFF.md): remaining
  tuple and owned-call increments; local/match flattening already exists.

Focused cleanup work lives in issues, not additional umbrella plans:
[module environment preparation](issues/module-environment-preparation-rebuilds-state.md),
[Perceus frame stacks](issues/perceus-frame-stacks-duplicate-traversal-storage.md), and
[Perceus managed-let bookkeeping](issues/perceus-managed-let-bookkeeping-allocates.md).

## Maintenance Rules

- Reference docs describe current behavior, not migration history.
- Open issues are files in [`issues/`](issues/), one per issue and named for
  the symptom: `Status: open`, the reproduction, the cause and the change that
  closes it. A fixture that pins a known failure names its issue file. GitHub
  is read-only for this project; assignees and discussion do not belong in this
  tree.
- A plan for active work lives in this directory and holds only open work.
  When a step lands, delete it from the plan in the same change (Git history
  keeps it), and delete the plan when nothing is open.
- Put raw performance evidence in `benchmarks/results/` and link it from the
  issue or plan that uses it.
- Keep common build, measurement, and landing recipes in the Worker Checklist
  and its linked references. Plans retain only task-specific commands and gates.
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
