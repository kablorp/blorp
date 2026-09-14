# Plan Compiler Checks Before Executing Them

**Status:** Proposed

**Owner:** `scripts/compiler-check` and its ownership manifest/tests

**Current state:** Owner selection, one build, and failure reruns exist; a
read-only plan and broad-gate explanation do not.
**Next action:** Test `--plan` against the production selector, then implement
its no-write view and surface the existing `broad_gate` authority.
**Read first:** `scripts/compiler-check` selection/validation and
`blorp/test/compiler/compiler_test_ownership.json`.
**Fast loop:** The proposed `test_compiler_check_plan.py` with a miniature
manifest; no compiler build for plan-only cases.
**Decision:** Accept only identical plan/run selections and a no-write plan;
reject invented ownership or a green claim for a no-op.

## Objective

Make `scripts/compiler-check` explain exactly what it will select and why,
without building or running anything, and give explicit next-gate guidance.
Preserve the current execution path: it already selects registered suites,
builds once, saves failure logs, and prints an exact rerun.

## Why

An agent often needs to know whether `--changed` includes a newly edited
module, whether a selected suite came from source ownership or a directly
changed test, and whether the focused selection is enough for the task. The
current command prints sources/suites/checks only when execution begins. For a
docs-only or bootstrap-pin edit it may select nothing and report success
without building. That no-op must not be mistaken for behavioral validation.
The manifest already requires every registered production module to reference
at least one focused suite and names one broad gate for it.

Selection authority is
`blorp/test/compiler/compiler_test_ownership.json`. Do not infer owners or
recommended gates from path substrings, recent failures, or import names.

## Proposed User Interface

The exact flag may be `--plan`; these examples define its behavior, not an
already implemented command.

```bash
# Propose the smallest check before spending build time.
scripts/compiler-check --changed --plan

# Include committed work since the selected merge base.
scripts/compiler-check --changed --base origin/main --plan

# Explain a known suite or an entire stage.
scripts/compiler-check blorp/test/compiler/stage_09_core/test_core_match.brp --plan
scripts/compiler-check --stage core --plan
```

Human output should distinguish selected facts from recommendations:

```text
Mode: plan only (no build, compiler, test, log, or generated-file write)
Changed production source: blorp/src/compiler/stage_09_core/match_lowering.brp
  owner stage: core
  focused suite: blorp/test/compiler/stage_09_core/test_core_match.brp
  selected special check: compiler-core-sanitize
Changed test: blorp/test/compiler/stage_09_core/test_core_match.brp
Focused action: make; bin/blorp test --timeout ... <exact selected suites>;
  scripts/test --no-build --serial compiler-core-sanitize
Recommended additional gate: scripts/test compiler-blorp
Reason: the module's existing broad_gate field; not run by --plan
```

`...` above means use the same timeout that the real command will use. The
real output must print literal executable commands, shell-quote paths safely,
and not claim an unselected gate ran. The existing `checks` and `broad_gate`
fields are distinct: selected checks run in execution mode; the broad gate is
review guidance only. A machine-readable `--json` form is
useful only if it reuses the same selection object and a versioned schema;
do not implement two selection algorithms merely for presentation.

### Empty and unsupported selection

```text
Selected 0 production sources, 0 suites, 0 special checks.
No compiler-focused behavior was selected for these changes. This is a no-op,
not a passing validation; use the task-specific build/docs/release checks.
```

`--changed --plan` on a bootstrap manifest or docs-only edit should say no
compiler production source was selected and direct the reader to task-specific
guidance, not print a green "compiler check passed". Execution mode may retain
its current exit semantics for compatibility, but its no-op message must be
equally explicit. An unowned production `.brp` source remains an error with
the manifest path and `--validate-manifest` fix command.

## Gate Recommendation Authority

Reuse each module's existing `broad_gate` field in the ownership manifest and
its registered special `checks`. Do not add a second stage-to-gate table.
For `match_lowering.brp`, the selected special check is
`compiler-core-sanitize`, while `compiler-blorp` is the named recommended
broad gate. If an edit's nature calls for more evidence than its module's one
broad gate, say "review task-specific gates" and link to the Developer Guide;
do not guess from a filename or enlarge this issue into gate policy redesign.
Keep recommendations visually separate from commands that execution mode
actually runs.

## Test-First Cases

Add focused Python tests under `blorp/test/build/` using a temporary miniature
repository/manifest and fake `make`/`bin/blorp`. Before implementation, show
that plan-mode cases fail because the flag is absent. Cover:

1. one changed module selecting exactly its registered suite and check;
2. a directly changed registered suite selecting itself;
3. staged, unstaged, untracked, and `--base` committed changes;
4. no changes, docs-only, and bootstrap-manifest-only changes selecting no
   production module; every valid production module still has a focused suite;
5. an unowned production module and an unknown stage/suite;
6. shell-special paths in displayed rerun commands;
7. plan mode causing no build, compiler execution, log directory, or generated
   file write;
8. human and optional JSON output representing the same selection; and
9. current execution behavior and retained failure artifacts unchanged.

Do not test a mock that reimplements changed-file selection; exercise the
production selector in `scripts/compiler-check`.

## Fast Feedback Loop

```bash
python3 blorp/test/build/test_compiler_check_plan.py
scripts/compiler-check --validate-manifest
scripts/compiler-check --changed --plan
```

The test module and `--plan` flag in this block are proposed artifacts. Once
stable, run the existing `blorp/test/build/test_scripts_test_harness.sh`, one
real `scripts/compiler-check --changed` on a known selected source/worktree,
and the relevant test-runner/code-reviewer reviews. The real run must still
build once and preserve exact failure reruns.

## Acceptance / Rejection

- [ ] `--plan` and execution use one selector and report the same chosen files.
- [ ] Plan mode performs no build/test and writes no repository artifacts.
- [ ] Recommendations cite explicit policy and cannot silently become gates.
- [ ] No-op selection is conspicuous, never a green test claim; missing suite
      ownership remains a manifest validation error.
- [ ] `--validate-manifest` is visible in `--help` with its actual behavior.
- [ ] Existing selection, build-once, failure-log, and rerun semantics pass
      regression tests.
- [ ] A fresh agent can choose the next command from the plan output without
      reading the Python implementation.
- [ ] If showing extra task-specific gates requires an unreliable edit-type
      classifier, omit those extras and keep the existing broad-gate field.

## Non-Goals

- Replacing `scripts/test` or automatically running broad gates.
- Inferring ownership from names/imports or timing estimates.
- A universal workflow runner for build, benchmarks, docs, and releases.
- Claiming every registered suite is sufficient to prove a production change.
