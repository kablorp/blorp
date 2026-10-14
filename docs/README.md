# Blorp Documentation

Start with the reference for your task. References describe current behavior;
plans describe proposed changes and remaining work, not available features.
Completed work belongs in Git history and benchmark results.

## Learn The Language

- [Learn Blorp in Y Minutes](LEARN_BLORP_IN_Y_MINUTES.md) is the concise tour
  and preferred-pattern guide.
- [Language Guide](GUIDE.md) is the complete source-language reference.
- [Formal Grammar](GRAMMAR.md) is the authoritative syntax: lexical structure,
  the layout algorithm, the EBNF, the position rules and the open grammar
  decisions.

## Use The Toolchain

- [Handoff Spec](HANDOFF_SPEC.md) is the required shape of every handoff,
  usually a message to an agent, including literate code examples.
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

The old compiler under `blorp/src` stays as the working host and receives fixes
only; plans to improve it are retired. [Compiler Faults](COMPILER_FAULTS.md)
lists its open defects. The successor
compiler and its plans live under [`blorp_2/`](../blorp_2/README.md).

## Maintenance Rules

- Reference docs describe current behavior, not migration history.
- Work is handed off in messages that follow the [Handoff Spec](HANDOFF_SPEC.md).
  A known problem that needs a durable record lives in the plan or ledger that
  owns it, such as [Compiler Faults](COMPILER_FAULTS.md). GitHub is read-only
  for this project; assignees and discussion do not belong in this tree.
- A plan for active work lives in this directory and holds only open work.
  When a step lands, delete it from the plan in the same change (Git history
  keeps it), and delete the plan when nothing is open.
- Summarize performance evidence in one markdown file in `benchmarks/results/`
  and link it from the plan that uses it. Keep raw samples under the ignored
  `build/` directory, and delete the report with the plan.
- Keep common build, measurement, and landing recipes in the Worker Checklist
  and its linked references. Plans retain only task-specific commands and gates.
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
