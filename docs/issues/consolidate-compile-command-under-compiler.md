# Consolidate the Compile Command Under Compiler Ownership

**Status:** Complete

## Issue Summary

Remove the redundant `blorp/src/compile/` production directory by moving the
`blorp compile` command boundary, artifact writer, and compiler-output rendering
under `blorp/src/compiler/`. Move the corresponding tests from
`blorp/test/compile/` to `blorp/test/compiler/` and update every manifest,
import, fixture, and architecture reference in the same change.

This is a focused ownership and path migration. It must preserve compilation
semantics, generated C, CLI output, exit status, timing output, build behavior,
and pipeline order. It must not redesign whole-compilation orchestration or
turn the move into a broad `lib` extraction.

## Context

The current layout gives one concept two production owners:

```text
blorp/src/compile/   # `blorp compile` command, output, artifact publication
blorp/src/compiler/  # frontend, Core, backend, and compiler pipeline
```

The distinction is technically explainable as “CLI adapter” versus “compiler
implementation,” but it is not useful in Blorp's owner-oriented source tree.
Compilation is one coherent subsystem. Its public command boundary and its
pipeline internals should be discoverable under one directory.

The executable composition rule remains:

- `blorp/src/main.brp` is the sole executable root;
- `main.brp` is the only production file permitted to compose arbitrary
  command and subsystem owners;
- non-`lib` command directories do not import sibling command directories;
- shared code used by multiple commands belongs in `blorp/src/lib/`; and
- compiler-only code belongs in `blorp/src/compiler/`.

This issue consolidates the physical owner without changing those dependency
rules.

## Problem Statement

Keeping both `compile/` and `compiler/` causes avoidable ambiguity:

1. A reader cannot infer whether compile-command behavior belongs under
   `compile/`, `compiler/`, or `lib/compilation.brp`.
2. Compiler-owned tests are split between `blorp/test/compile/` and
   `blorp/test/compiler/`.
3. Compiler-check ownership manifests and build-check fixtures must encode the
   artificial split.
4. Future compilation behavior has no obvious home, increasing the chance of
   new cross-directory dependencies.
5. The path split suggests an architectural boundary that the production flow
   does not actually have.

## Desired Layout

After this issue, compilation has one production and test owner:

```text
blorp/
  src/
    main.brp
    compiler/
      command.brp
      artifact_writer.brp
      output.brp
      pipeline.brp
      bridge_protocol.brp
      frontend_output.brp
      frontend_request.brp
      stage_01_generated_inputs/
      ...
      stage_10_backend/
    lib/
      compilation.brp
      compile_plan_execute.brp
      compilation_timing.brp
      ...
  test/
    compiler/
      test_command.brp
      test_artifact_writer.brp
      test_output.brp
      pipeline/
      stage_01_generated_inputs/
      ...
```

There must be no `blorp/src/compile/` or `blorp/test/compile/` directory after
the migration.

## Dependency And Ownership Rules

The resulting imports must follow this shape:

```text
main.brp
  -> compiler/command.brp
  -> run/command.brp
  -> test/...
  -> other command owners

compiler/command.brp
  -> compiler-owned command helpers
  -> shared lib modules

compiler stages and pipeline
  -> compiler modules
  -> genuinely shared lib modules

run/, test/, check/, format/, purify/, lint/, package/, lsp/
  -> their own modules
  -> genuinely shared lib modules
  X  compiler/command.brp
```

Only `main.brp` may import across arbitrary owners. Moving the compile command
under `compiler/` must not make `run`, `test`, or another command import the
compiler command module. Existing shared compilation entry points remain in
`lib` when multiple commands use them.

## Shared `lib` Rule

Do not move a function from `lib` merely because its name or implementation is
compiler-related. Reuse determines ownership.

A declaration may move from `lib` to `compiler` only when a repository-wide
consumer audit shows that:

- its semantic consumers are exclusively the compile command or compiler
  internals;
- no other command imports it directly;
- no shared public `lib` operation uses it on behalf of another command; and
- moving it does not force another command to import `compiler` or duplicate
  the implementation.

Count semantic/transitive use, not only direct import lines. A private helper
inside a shared compilation operation still supports every command that calls
that operation.

The following current modules are shared and are therefore **not relocation
targets for this issue**:

| Module | Current cross-command use |
| --- | --- |
| `lib/cli_args.brp` | `main`, `run`, `format`, `test`, and `lint`, plus shared planning/environment modules |
| `lib/cli_plan.brp` | `main`, `compile`, `run`, `check`, `test`, `package`, `purify`, and `lint` |
| `lib/compilation.brp` | compile output plus `run` and `test` compilation paths |
| `lib/compile_plan_execute.brp` | compile, run, and shared run effects |
| `lib/run_effect.brp` | run and test execution |
| `lib/frontend_validation.brp` | check, package, purify, and lint |
| `lib/source_graph.brp` | main, package, test, and purify |

Likewise, do not move `CompileArtifactOutput`, `CompileObservation`,
`RunArtifactExecution`, `CompileTiming`, `BuildArtifact`, or another shared
type solely to make the compiler directory look self-contained. A shared data
contract belongs in `lib` when multiple command owners consume it.

If the implementation discovers an apparently compiler-specific `lib` helper,
record its direct and semantic consumers before moving it. When ownership is
ambiguous, leave it in place and record a follow-up rather than broadening this
issue.

## Exact Production Moves

Perform these moves without copying the implementations:

| Current path | Target path |
| --- | --- |
| `blorp/src/compile/command.brp` | `blorp/src/compiler/command.brp` |
| `blorp/src/compile/artifact_writer.brp` | `blorp/src/compiler/artifact_writer.brp` |
| `blorp/src/compile/output.brp` | `blorp/src/compiler/output.brp` |

Update relative imports after the move. In particular:

- `compiler/command.brp` should import `../lib/...` shared modules and its
  sibling `artifact_writer` and `output` modules;
- `main.brp` should import `compiler/command`, not `compile/command`;
- no forwarding module should remain at the old path; and
- no compatibility alias should preserve the old module identities.

This is a pre-0.1 internal source move. Update all repository consumers at
once.

## Exact Test Moves

Move the mirrored tests with their owner:

| Current path | Target path |
| --- | --- |
| `blorp/test/compile/test_command.brp` | `blorp/test/compiler/test_command.brp` |
| `blorp/test/compile/test_artifact_writer.brp` | `blorp/test/compiler/test_artifact_writer.brp` |
| `blorp/test/compile/test_output.brp` | `blorp/test/compiler/test_output.brp` |

Update the tests to import `src/compiler/...`. Do not retain duplicate test
files or leave a compatibility test directory.

The test names already use the required `test_` prefix and should retain it.
No nested `test/` directory should be created under production source.

## Manifest, Tooling, And Documentation Updates

Update all path-sensitive owners in the same change:

1. Change the three suite paths and three production ownership entries in
   `blorp/test/compiler/compiler_test_ownership.json`.
2. Update the compile-path fixture in
   `blorp/test/compiler/build/test_compiler_check.py` so it proves changed
   `src/compiler/command.brp` selects the relocated command suite.
3. Search the complete repository for `blorp/src/compile`,
   `blorp/test/compile`, and `compile/command` and update active references.
4. Update `docs/ARCHITECTURE.md` to name `compiler/command.brp` as the compile
   CLI boundary while retaining `compiler/pipeline.brp` as the only
   authoritative phase-order manifest.
5. Update active issue documents only when an old path is intended to identify
   current code. Historical descriptions may remain historical when changing
   them would misrepresent completed work.
6. Update generated inventories only through their owning deterministic
   generator; do not hand-edit generated outputs.

## Implementation Sequence

### 1. Establish The Baseline

Before moving files, run the three focused tests and the compiler-check build
tests. Record the passing baseline so path-migration failures can be separated
from pre-existing failures.

### 2. Move Production And Mirrored Tests Together

Move each source file and its test in the same working change, then update
imports immediately. Do not copy first and delete later; the tree should have
one active module identity for each responsibility.

### 3. Update Ownership Metadata

Update `compiler_test_ownership.json` and the `compiler-check` fixtures before
running broad suites. The changed-source selector must understand the final
paths rather than relying on a temporary exception.

### 4. Audit `lib` Consumers

Run a repository-wide import and symbol search for any `lib` declaration being
considered for relocation. Keep all declarations that serve another command,
directly or through a shared operation. This audit is a guardrail, not an
invitation to reorganize every compiler-coupled `lib` file.

### 5. Remove Old Paths And Update Documentation

Delete the empty `src/compile` and `test/compile` directories, update current
documentation, and verify that no production, test, build, or CI reference
uses the old paths.

## Tests And Verification

Run at minimum:

```bash
make
bin/blorp test blorp/test/compiler/test_artifact_writer.brp
bin/blorp test blorp/test/compiler/test_output.brp
bin/blorp test blorp/test/compiler/test_command.brp
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  blorp/test/compiler/build/test_compiler_check.py
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test cli
```

Also perform direct CLI smoke checks for:

- `blorp compile` producing a C artifact at the default path;
- `blorp compile -o` producing an artifact at the requested path;
- `--dump-typed-ast` output;
- `--dump-core-after` output;
- `--time-phases` output; and
- a compile failure preserving its current diagnostic and nonzero status.

Because this is a path-only ownership migration, generated C for at least one
representative fixture should be byte-identical before and after the move. A
material difference indicates accidental behavior change and must be
investigated.

Run:

```bash
git diff --check
rg -n 'blorp/src/compile|blorp/test/compile|(^|[[:space:]])compile/command' \
  blorp/src blorp/test scripts Makefile docs .github
```

The final search should return no active old-path references. Any intentionally
historical documentation hit must be reviewed explicitly.

## Performance And Build-Time Requirement

No performance improvement is required. The move must not introduce a clear
build-time or command-latency regression.

In particular:

- do not add forwarding modules or duplicate imports that enlarge the
  self-hosted compiler graph;
- do not cause the same source module to be compiled under two identities;
- compare one changed-source build before and after the move; and
- confirm the no-op build remains fast.

A noisy timing difference is acceptable; a repeatable regression requires
diagnosis before merge.

## Explicit Non-Goals

This issue does not:

- redesign `lib/compilation.brp`;
- introduce a compilation capability or dependency-injection framework;
- move shared compilation functions out of `lib`;
- reorganize `run`, `test`, `check`, `format`, `purify`, `lint`, `package`, or
  `lsp`;
- reorder or otherwise alter the compiler pipeline;
- change compiler diagnostics, generated C, artifact contents, or CLI output;
- add compatibility modules at the old paths;
- add a global import-policy checker;
- rename the public `compile` subcommand; or
- pin a new bootstrap compiler unless the source move unexpectedly requires a
  language change, which should instead be treated as a blocker and separated
  from this issue.

## Acceptance Criteria

- [ ] `blorp/src/compile/` no longer exists.
- [ ] `blorp/test/compile/` no longer exists.
- [ ] Compile command, artifact writer, and output renderer live directly under
      `blorp/src/compiler/`.
- [ ] Their tests live directly under `blorp/test/compiler/` with `test_`
      prefixes.
- [ ] `main.brp` imports `compiler/command` as the compile-command entry point.
- [ ] No non-`main` command module imports `compiler/command` or a sibling
      command owner.
- [ ] Shared `lib` declarations used by other commands remain in `lib`.
- [ ] No copied implementation, forwarding module, compatibility alias, or
      duplicate test remains.
- [ ] `compiler/pipeline.brp` remains the sole compiler phase-order manifest.
- [ ] Compiler-check ownership and selector fixtures use the new paths.
- [ ] Active source, tests, tooling, CI, and architecture documentation contain
      no stale old-path references.
- [ ] Focused compiler command tests, compiler-check tests, compiler-owned
      suites, and CLI gates pass.
- [ ] Representative generated C is unchanged.
- [ ] Changed-source and no-op builds show no clear regression.
- [ ] Any ambiguous `lib` ownership findings are recorded as follow-ups rather
      than folded into this migration.

## Follow-Up Boundary

After this issue, separately evaluate whether any remaining `lib` modules mix
shared contracts with compiler-only implementation. Such a follow-up must begin
with a per-declaration consumer audit. It may move only exclusive compiler
implementation while preserving shared operations in `lib`; it must not make
other commands import `compiler` or recreate the removed `compile` owner under
a different name.

## Completion Evidence

- The three production modules moved with byte-identical contents.
- Their three mirrored suites moved with only module-import path updates and
  formatter-required import ordering.
- The source-layout and compiler-check contract suites passed all 35 tests.
- `scripts/compiler-check --changed` passed 4 selected sources, 5 focused
  suites, and 4 integration checks.
- `scripts/test --serial compiler-blorp` passed all 4,116 tests on the final
  rebased commit.
- The three relocated focused suites passed all 8 tests after final formatting.
- Bootstrap and current compilers emitted byte-identical C for a representative
  managed-local tuple fixture.
- A changed-source build completed in 70.15 seconds; the following no-op build
  completed in 0.63 seconds.
