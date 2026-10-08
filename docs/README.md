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

[Diagnostic Gaps](DIAGNOSTIC_GAPS.md) owns diagnostic-quality findings and
indexes compiler faults.

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
- [Record Allocation](RECORD_ALLOCATION_ROADMAP.md): incremental container and
  transport-box removal, shared ownership/storage, and checked inline policy.
- [Union Simplification](FIXED_UNION_ROADMAP.md): enum migration, one logical
  union model, shared representations, and later checked fixed unions.
- [Allocation Contracts](ALLOCATION_CONTRACT_ROADMAP.md): incomplete backend
  coverage and proposed `no_alloc` enforcement. The existing report is
  described in [Architecture](ARCHITECTURE.md#allocation-reports).
- [Discovery Acceptance](DISCOVERY_ACCEPTANCE_ROADMAP.md): parser differences
  and retiring legacy consumers. [Discovery Redesign](DISCOVERY_REDESIGN.md)
  separately proposes typed syntax trees; that path is not implemented.
- [Product Unification](PRODUCT_UNIFICATION.md): one Core product model for
  records and tuples, scalar replacement across calls, multi-values and typed
  tuple boxes.
- [Tuple Record Storage](TUPLE_RECORD_STORAGE.md): approved implementation order
  for shared construction, runtime interfaces and tuples through record layouts.
- [Value Tuples And State Handoff](VALUE_TUPLES_AND_STATE_HANDOFF.md): owned
  state through calls, last-use and field-place increments, and stored
  products; local/match flattening already exists.

## Maintenance Rules

- Reference docs describe current behavior, not migration history.
- Work is handed off in messages that follow the [Handoff Spec](HANDOFF_SPEC.md).
  A known problem that needs a durable record lives in the plan or ledger that
  owns it, such as [Diagnostic Gaps](DIAGNOSTIC_GAPS.md). GitHub is read-only
  for this project; assignees and discussion do not belong in this tree.
- A plan for active work lives in this directory and holds only open work.
  When a step lands, delete it from the plan in the same change (Git history
  keeps it), and delete the plan when nothing is open.
- Put raw performance evidence in `benchmarks/results/` and link it from the
  plan that uses it.
- Keep common build, measurement, and landing recipes in the Worker Checklist
  and its linked references. Plans retain only task-specific commands and gates.
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
