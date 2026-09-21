# Blorp Documentation

The references below describe the current language, toolchain, and
implementation. The short priorities map and issue index describe future
work. Completed implementation history belongs in Git history and benchmark
results, not in maintained docs.

## Learn The Language

- [Learn Blorp in Y Minutes](LEARN_BLORP_IN_Y_MINUTES.md) is the concise tour
  and preferred-pattern guide.
- [Language Guide](GUIDE.md) is the complete source-language reference.
- [Formal Grammar](GRAMMAR.md) is the parser-level EBNF contract.

## Use The Toolchain

- [Worker Checklist](WORKER_CHECKLIST.md) is the one page to read before
  starting a compiler or compiler-performance task: setup, fast feedback
  loop, measurement, and landing rules.
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
- [Memory Model](MEMORY_MODEL.md) explains source-level value semantics, ARC,
  and copy-on-write behavior.
- [Ownership Model](OWNERSHIP_MODEL.md) defines the compiler/runtime ownership
  ABI for managed values.
- [Concurrency And Resources](CONCURRENCY_AND_RESOURCES.md) defines structured
  concurrency, cancellation, resources, streams, and networking contracts.

## Plan Current Work

- [Compiler Priorities](COMPILER_PRIORITIES.md) is the short cross-cutting
  outcomes map.
- [Compiler Speed Roadmap](COMPILER_SPEED_ROADMAP.md) is the task-level
  plan for the next rounds of compiler speed work.
- [Per-Node Codegen Roadmap](PER_NODE_CODEGEN_ROADMAP.md) is the task-level
  plan for cutting the per-node cost of generated C (reference counting,
  cleanup frames, runtime calls), with the stage-2 measurement rule.
- [Allocation Contract Roadmap](ALLOCATION_CONTRACT_ROADMAP.md) proposes
  allocation explanations and a compile-time `no_alloc` block, including
  runtime/cleanup coverage, Core analysis, and tooling enforcement.
- [Frontend Facts Roadmap](FRONTEND_FACTS_ROADMAP.md) is the task-level
- [`SOURCE_DISCOVERY_PERFORMANCE_ROADMAP.md`](SOURCE_DISCOVERY_PERFORMANCE_ROADMAP.md) — lexer/parser/discovery cuts (Task 4 landed; rest deferred), with its profile in `benchmarks/results/`.
  plan for publishing each stage's facts as id-keyed tables (module,
  name, definition tables) and removing threaded state from typecheck.
- [Compact Parser Migration](COMPACT_PARSER_MIGRATION.md) defines the staged
  schema, ownership, compatibility, and measurement contract for replacing
  per-expression parser trees without creating a second permanent parser.
- [Self-Compile Measurement Protocol](../benchmarks/README.md#self-compile-measurement-protocol)
  is the standard compiler-performance measurement and its retained baselines.

## Maintenance Rules

- Reference docs describe current behavior, not migration history.
- Active implementation status, assignees, and discussion belong in GitHub
  issues. This tree holds no issue documents; a handoff that needs durable
  acceptance criteria records them in the GitHub issue and its measurement in
  `benchmarks/results/`.
- Put raw performance evidence in `benchmarks/results/` and link it from the
  issue or change that uses it.
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
