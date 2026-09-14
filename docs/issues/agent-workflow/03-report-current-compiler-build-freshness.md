# Report Whether The Local Compiler Matches Current Inputs

**Status:** Proposed

**Owner:** Makefile build identity, a small read-only status command, and the
Developer Guide's direct-test loop

## Objective

Give agents a cheap, truthful answer to: "Does `bin/blorp` represent the
compiler sources and build inputs in this worktree?" Use it before direct
focused tests. Do not make `bin/blorp` itself depend on the source tree, and do
not rebuild merely to answer the question.

## Why

`scripts/compiler-check` already runs `make` before selected suites. Direct
`bin/blorp check`, `test`, and `compile` do not. A test can therefore pass with
yesterday's compiler after today's compiler source edit. This is particularly
misleading for self-hosting: the changed source may check under the old binary
but fail when the bootstrap compiler generates and the host C compiler builds
the new one.

The Makefile already records content-derived identities for compiler C and the
native CLI under `blorp/build/_build/`. Reuse that authority. A timestamp-only
`make -q` check, `bin/blorp --version`, or a Git commit comparison is not
sufficient: uncommitted source, standard-library inputs, runtime C, flags,
bootstrap assets, generated files, and worktree-specific paths can matter.

## Proposed User Interface

Call the command `scripts/compiler-build-status` unless a clearer existing
entry point emerges. These examples specify intended behavior; the command
does not exist yet.

```bash
make
scripts/compiler-build-status
# FRESH: bin/blorp matches current compiler build inputs

bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_match.brp
```

After editing compiler source:

```bash
scripts/compiler-build-status
# STALE: blorp/src/compiler/stage_09_core/match_lowering.brp changed
# Next: make

make
scripts/compiler-build-status --quiet
bin/blorp test --timeout 180 \
  blorp/test/compiler/stage_09_core/test_core_match.brp
```

`--quiet` is for scripts: exit 0 for proven fresh, 1 for stale, and 2 for
unknown/unverifiable (such as missing provenance, unsupported configuration, or
an unreadable input). Human output must distinguish stale from unknown and
name the reason and remedy. A `--json` option is optional; if added, version
its schema and retain the same three states.

The documented quick loop should read:

```text
make once after a coherent compiler edit → check freshness → repeat the exact
focused bin/blorp test as needed → scripts/compiler-check --changed before
integration → relevant broad scripts/test gates.
```

`--no-build` on `scripts/test` is an intentional assertion by the caller. Do
not silently rebuild in that mode; a later integration can invoke the same
read-only freshness check and fail with a helpful message if the assertion is
false. That extension is optional and must preserve CI's prepared-toolchain
workflow.

## Identity And Safety Requirements

1. Determine the installed `bin/blorp` and its build identity using the same
   source-of-truth inputs as Make. Verify recorded artifact hashes, not only
   the presence of stamp files.
2. Include compiler `.brp`, relevant standard-library `.brp`, bootstrap pin or
   override, generator inputs, native runtime sources, build recipes/flags,
   and generated artifacts exactly to the extent Make says they affect the
   binary. If a category cannot be verified cheaply, report `UNKNOWN`.
3. Never claim `FRESH` for a copied binary without a matching, verifiable
   current-input identity, or when its recorded hash disagrees with its actual
   bytes. A byte-identical copy with fully matching provenance need not be
   rejected solely because it was built in another worktree.
4. Running status must not download, generate, compile, reformat, mutate cache,
   or update Make stamps. It may read files and hash content.
5. Avoid duplicating Make's long hash recipe in a second implementation. A
   small semantics-preserving extraction of an input-fingerprint helper is
   acceptable if independently tested. Stop and rescope if this turns into a
   build-system redesign.
6. Report the exact configured bootstrap/compiler overrides when they affect
   freshness. Do not assume a user's ambient environment is irrelevant.

## Test-First Cases

Write a focused build-status test under `blorp/test/build/` before the helper.
Use tiny temporary fixtures and controlled hashes; do not require a full
compiler build for every case. Cover:

- freshly built binary and unchanged source;
- one compiler source edit, including unstaged and untracked input;
- standard-library source and runtime C edits;
- bootstrap pin/override and native compile flag change;
- missing binary, missing hash, altered binary bytes, or corrupted manifest;
- copied binary/stamp from a different worktree;
- unsupported platform or unreadable input returning `UNKNOWN`, not `FRESH`;
- status command leaves tracked files, build outputs, and cache unchanged;
- an actual `make` followed by `scripts/compiler-build-status` reports fresh.

The first tests should fail because no status command exists. Do not fake the
entire Make identity in tests and then claim the real build path is covered;
retain one real integration smoke.

## Fast Feedback Loop

```bash
python3 blorp/test/build/test_compiler_build_status.py
scripts/compiler-build-status
git diff --check
```

The Python file and status command are proposed. During implementation, run
the synthetic tests first, then one real `make`/freshness smoke, then mutate a
single temporary worktree input to prove the stale transition. Run
`blorp/test/build/test_build_configuration.sh` and the test-runner/code-reviewer
reviews before accepting build-identity changes.

## Acceptance / Rejection

- [ ] Proven fresh, stale, and unverifiable states are distinct in exit code
      and user-facing text.
- [ ] Real `make` followed by status is fresh; relevant input edits turn stale.
- [ ] Corrupt/missing provenance and copied binaries never appear fresh.
- [ ] No build, download, generated output, or cache write occurs during status.
- [ ] Warm status latency is measured and low enough for every direct-test loop
      (aim under two seconds on the compiler checkout; report actual numbers).
- [ ] Developer Guide examples put freshness before direct `bin/blorp` tests
      without adding ceremony to `scripts/compiler-check`.
- [ ] If faithful identity cannot be computed cheaply, reject a misleading
      green check; deliver an explicit `UNKNOWN` with `make` guidance instead.

## Non-Goals

- Auto-building on every `bin/blorp` invocation.
- Replacing content-addressed Make identities with mtimes.
- Proving that a fresh compiler is correct; tests still do that.
- Broad changes to CI caching or release packaging.
