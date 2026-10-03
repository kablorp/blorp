# Blorp Documentation

The references below describe the current language, toolchain, and
implementation. The priorities map, the plans and the open issues describe
future work and hold only what is still open. Completed implementation history
belongs in Git history and benchmark results, not in maintained docs.

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
- [Memory Model](MEMORY_MODEL.md) explains source-level value semantics, ARC,
  and copy-on-write behavior.
- [Ownership Model](OWNERSHIP_MODEL.md) defines the compiler/runtime ownership
  ABI for managed values.
- [Concurrency And Resources](CONCURRENCY_AND_RESOURCES.md) defines structured
  concurrency, cancellation, resources, streams, and networking contracts.

## Plan Current Work

- [Diagnostic Gaps](DIAGNOSTIC_GAPS.md) is the living ledger of weak compiler
  diagnostics ranked by return on investment; add an entry when you meet one.
Plans hold only open work: completed steps, measurements and rejected
experiments live in Git history and `benchmarks/results/`.

- [Compiler Priorities](COMPILER_PRIORITIES.md) is the short cross-cutting
  outcomes map and the rules for the next round of speed work.
- [`issues/`](issues/) holds the open issues, one file each: reproduction,
  cause and the change that closes it.
- [Compiler Speed Roadmap](COMPILER_SPEED_ROADMAP.md) lists the open
  compiler-speed items (production invariant walks, late-Core walk fusion,
  cancellation re-analysis) and the working rules for profiling them.
- [Per-Node Codegen Roadmap](PER_NODE_CODEGEN_ROADMAP.md) lists the open work
  on the per-node cost of generated C (reference counting, cleanup frames,
  out-of-line runtime calls) and points at the stage-2 measurement rule.
- [Identity And Tables Roadmap](IDENTITY_ROADMAP.md) is the one plan for names
  to ids, retiring magic spellings, emission by id, value identity through the
  front end and Core, type identity and interning, Core node tables and
  frontend facts, with each step's oracle and the interim states still on main.
- [Struct Payload Roadmap](STRUCT_PAYLOAD_ROADMAP.md) lists the open steps for
  keeping struct values inline in unions, tuples and dictionaries, and
  converting hot records to structs.
- [Allocation Contract Roadmap](ALLOCATION_CONTRACT_ROADMAP.md) proposes
  allocation explanations and a compile-time `no_alloc` block, including
  runtime/cleanup coverage, Core analysis, and tooling enforcement.
- [Discovery Acceptance Roadmap](DISCOVERY_ACCEPTANCE_ROADMAP.md) lists what
  remains after the discovery stage became the default front end: the two
  known parser differences, hardening, the adapter's shrinkage and the plan to
  remove the old front end.
- [Discovery Tables Design](DISCOVERY_TABLES_DESIGN.md) describes the
  implemented discovery schema (node table, definition ids minted in
  discovery, packed spans) under `blorp/src/compiler_new/stage_01_discovery/`.
- [Discovery Redesign](DISCOVERY_REDESIGN.md) is a design for review:
  discovery as independent per-module parses into typed syntax trees with
  parser-stamped ids, one link step and no freeze checks.
- [Perceus Cleanup Issues](PERCEUS_CLEANUP_ISSUES.md) lists the open
  worker-ready Perceus cleanups and the allocation floor rules.
- [Typecheck Optimization Issues](TYPECHECK_OPTIMIZATION_ISSUES.md) holds the
  open typecheck allocation issue (module environment preparation) and the
  rules the rejected cuts taught.
- [Value Tuples And State Handoff](VALUE_TUPLES_AND_STATE_HANDOFF.md)
  is the plan of record for tuple flattening, owned state through calls, and
  stored tuple layout. It distinguishes current `main` from the validated,
  unmerged local-tuple pilot and keeps later increments as proposals.
- [Self-Compile Measurement Protocol](../benchmarks/README.md#self-compile-measurement-protocol)
  is the standard compiler-performance measurement and its retained baselines.

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
- Prefer generated inventories and `--help` output over copied file, command,
  flag, keyword, or declaration lists.
- When implementation, tests, and docs disagree, verify the implementation and
  tests, then update the relevant reference document in the same change.
