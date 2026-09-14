# Route Agent Tasks To Owners And Feedback Loops

**Status:** Proposed

**Owner:** `AGENTS.md`, `docs/DEVELOPMENT.md`, and `docs/README.md`

## Objective

Give an agent a short, accurate entry point from a user request to the owning
source, contract, smallest useful test, and final validation gate. Keep detailed
rules in their existing owners. This is documentation routing, not a new policy
layer or a second compiler architecture description.

## Why

The repository has strong instructions, but a first-time agent must reconcile
`AGENTS.md`, the Developer Guide, architecture, script docs, and issue handoffs
before choosing a command. Reading all of them is useful for a broad design
task; it is slow for a small diagnostic or bootstrap-pin change. In particular,
`scripts/compiler-check --changed` is appropriate for registered production
compiler source, not every file in the repository. A routing page should make
that distinction immediately visible.

## Required Routing Contract

Put one first-screen table or decision guide near the top of `AGENTS.md` and
link to it from the Developer Guide. Each route must name:

1. the first authoritative implementation/contract to read;
2. where a failing test belongs;
3. the narrowest repeatable command after the compiler is built;
4. the owner-selected or integration gate before review; and
5. one characteristic trap, such as stale `bin/blorp` or generated C beside a
   source file.

At minimum cover parser/diagnostics, inference/typechecking, Core/ownership,
backend/runtime, CLI/LSP, standard library, build/bootstrap, documentation,
and compiler performance. Link to [Developer Guide](../../DEVELOPMENT.md),
[Architecture](../../ARCHITECTURE.md), and [Scripts](../../../scripts/README.md)
rather than copying their entire command inventories. Do not move language
principles, review rules, or phase-boundary constraints out of `AGENTS.md`.

### Example: parser diagnostic

A useful route should let an agent derive this sequence without reading every
stage guide first:

```text
Request: "Make a missing ')' diagnostic show a helpful suggestion."
Read: stage_03_parse parser + matching should_fail fixture and grammar.
First test: the exact public parser fixture, including expected message text.
Narrow loop: bin/blorp check --no-format <fixture>.brp
Owner check: scripts/compiler-check --changed
Final: relevant compiler-blorp gate and GUIDE/GRAMMAR sync if syntax changes.
```

These placeholders are explanatory, not literal runnable filenames. The actual
route must link to existing source/test directories and say that public
diagnostics assert message content, not only a failing exit code.

### Example: Core ownership change

```bash
# Inspect the producer/consumer boundary and an exact focused suite first.
rg -n 'CoreSemanticMatch|replace_semantic_match_fail' \
  blorp/src/compiler/stage_09_core blorp/src/compiler/stage_10_backend
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_match.brp
scripts/compiler-check --changed
scripts/test compiler-core-sanitize
```

The route must point to `pipeline.brp`, `pipeline_stage.brp`, and Core snapshots
for a pass-order change, and say when generated C must be read.

### Example: bootstrap-pin change

```bash
scripts/blorp-compiler-bootstrap --print-id
make
bash blorp/test/build/test_build_configuration.sh
bash blorp/test/build/test_release_toolchain.sh
scripts/test --no-build
```

This route must say to verify *all* target asset checksums against the immutable
release and to update `blorp/build/bootstrap.env` as one manifest. It must not
suggest that `scripts/compiler-check --changed` covers the pin: that command
selects production compiler sources and registered suites.

### Example: performance claim

```text
First: identify the production function and exact measured boundary.
Then: run an isolated fixture with work/allocation counters and paired timings.
Finally: confirm the same compiler source through C emission, excluding host-C
compilation of the target, and inspect output identity.
```

The route should link to the existing profiling section and issue 04 in this
workstream. It must not promise a speedup from a synthetic call-count reduction.

## Implementation Steps

1. Inventory the current first-click paths from `README.md`, `AGENTS.md`, and
   `docs/README.md`; identify duplication but do not rewrite all three.
2. Draft the routing table using only named current commands and existing
   ownership boundaries. Have one agent unfamiliar with a selected subsystem
   use the draft to find a source/test pair.
3. Add the concise route to `AGENTS.md`; keep detailed command semantics in
   `docs/DEVELOPMENT.md` and `scripts/README.md`.
4. Remove only directly duplicated or contradictory nearby text. Do not
   reformat the full instruction file or alter policy in this issue.
5. Check every path, command, and cross-document link after the edit.

## Fast Feedback Loop

This is a documentation change. Use read-only command/help checks, link checks,
`git diff --check`, and a three-task routing exercise before broad tests. The
exercise should give a reviewer only each request above and ask them to name
the owner, first test, narrow command, and final gate. Record where the draft
still caused a wrong or ambiguous choice.

## Acceptance / Rejection

- [ ] The three example requests lead to the correct source/test/gate without
      requiring a full read of the Developer Guide.
- [ ] A standard-library or LSP request also routes correctly in review.
- [ ] The route distinguishes direct `bin/blorp` tests from
      `scripts/compiler-check --changed`, including build freshness.
- [ ] All linked paths and shown runnable commands exist and have the claimed
      behavior; no invented flag is presented as current.
- [ ] No language principle, safety rule, or phase-boundary requirement is lost.
- [ ] The new entry point is short enough to scan before acting; if it grows
      into another comprehensive guide, reject that shape and keep links only.
- [ ] Documentation review and link/whitespace checks pass.

## Non-Goals

- Reorganizing compiler directories or changing test ownership.
- Adding a universal `scripts/dev` command.
- Copying complete build and test instructions into `AGENTS.md` again.
- Changing the runtime behavior or CLI of Blorp.
