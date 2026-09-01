# Separate and Rename the Standard Library Source and Test Roots

**Status:** Complete; logical-namespace constraints superseded by the later
bare-standard-library namespace migration.

**Type:** Mechanical repository-layout migration

## Objective

Move the physical standard-library tree from `std/` to `standard_library/`,
with production modules under `src/` and tests under `test/`:

```text
standard_library/
  README.md
  src/
    prelude.brp
    test.brp
    list.brp
    dict.brp
    net/
  test/
    test_check_std_builtins.py
    list/
    dict/
    ...
```

This document records the earlier physical repository-path migration. Its
requirements to retain the logical `std/*` namespace are historical and no
longer describe current behavior.

## Motivation

The current `std/` tree contains approximately 91 production `.brp` modules,
71 test `.brp` files, and one Python policy test. Production and test sources
therefore share one filesystem source root.

That creates concrete problems:

- `std/test.brp` and the `std/test/` directory are easy to confuse.
- `embedded_std_modules` in `blorp/tool/generate_build_sources.brp` recursively
  embeds every `.brp` beneath its input directory. Passing `std` therefore
  makes standard-library test files eligible for embedding.
- `scripts/test std-check` currently traverses `std`, so it does not express a
  production-only standard-library check.
- The doctest gate traverses `std`, mixing the production and test roots.
- Compiler build manifests and CI cache keys cannot cleanly distinguish
  production standard-library changes from test-only changes.

The new layout makes the production source boundary explicit and aligns the
standard library with the repository's `src`/`test` ownership convention.

## Required Invariants

The following language and public-tooling behavior must remain unchanged:

- Logical module identities remain `std/list`, `std/test`, `std/prelude`, and
  so on.
- `standard_library/src/test.brp` remains the production `std/test` module.
- Source imports such as `std/test: TestSuite` remain unchanged.
- Compiler constants and builtin identities containing `std/...` remain
  unchanged.
- `BLORP_STD` and `--std-dir` retain their current names and semantics: their
  value is a path to the production standard-library source root.
- Package compatibility value `std` remains unchanged.
- Embedded standard-library URI/provider behavior remains unchanged.
- Diagnostics describing the logical `std` namespace remain unchanged.

Do not perform a global replacement of `std/` with
`standard_library/src/`. Every match must first be classified as either a
physical repository path or a logical module identity.

## Non-Goals

- Do not redesign module loading or import resolution.
- Do not rename `BLORP_STD`, `--std-dir`, or logical `std/*` identities.
- Do not add a compatibility symlink, fallback `std/` directory, or duplicate
  discovery root.
- Do not reorganize individual library APIs or test contents.
- Do not restructure `pkg/`.
- Do not change compiler behavior beyond selecting the correct physical
  source and test roots.
- Do not combine unrelated cleanup with this migration.

## Implementation Plan

### 1. Establish failing layout contracts

Update the existing build and harness tests before moving files. The tests must
require all of the following:

- `standard_library/src/` exists.
- `standard_library/test/` exists.
- top-level `std/` does not exist.
- production `.brp` files are under `standard_library/src/`.
- standard-library tests are under `standard_library/test/`.
- the embedded module list includes `std/test` from `src/test.brp`.
- no embedded module name starts with `std/test/`.
- `std-check` passes the absolute `standard_library/src` path as both
  `--std-dir` and the checked source root.

Prefer extending these existing contracts:

- `blorp/test/build/test_build_source_generator.sh`
- `blorp/test/build/test_build_configuration.sh`
- `blorp/test/build/test_scripts_test_harness.sh`
- `blorp/test/build/test_blorp_source_layout.py`

Run the new assertions against the old layout and record the expected failure
before implementing the move.

### 2. Move the files with history

Use `git mv`, preserving file history:

```text
std/README.md -> standard_library/README.md
std/*.brp     -> standard_library/src/*.brp
std/net/      -> standard_library/src/net/
std/test/     -> standard_library/test/
```

Delete the empty `std/` directory. Do not leave a symlink or placeholder.

### 3. Name the physical roots in the Makefile

Define the physical roots once near the top of `Makefile`:

```make
STANDARD_LIBRARY_SOURCE_ROOT := standard_library/src
STANDARD_LIBRARY_TEST_ROOT := standard_library/test
```

Use those variables for:

- standard-library production source discovery;
- embedded standard-library generation;
- Blorp CLI build-input manifests;
- runtime and security test roots;
- the standard-library Python policy test;
- generated-C cleanup.

Only `STANDARD_LIBRARY_SOURCE_ROOT` may contribute modules to the compiler
binary and compiler input hash. Test-only changes must not rebuild the embedded
standard library.

### 4. Correct embedded-source generation

Change the build generator invocation from:

```bash
generate-build-sources embedded-std std
```

to:

```bash
generate-build-sources embedded-std standard_library/src
```

Regenerate and commit
`blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp`.

The generated logical names must be unchanged for every production module:

```text
standard_library/src/list.brp -> std/list
standard_library/src/net/tcp.brp -> std/net/tcp
standard_library/src/test.brp -> std/test
```

The generated source must not contain a module whose name starts with
`std/test/`.

### 5. Update physical source-root defaults

Update repository-default physical paths, including the auto-format exclusion
in `blorp/src/main.brp`, from `std` to `standard_library/src`.

Do not change `configured_std_module_name` in
`blorp/src/lib/source_graph.brp`: it must continue converting paths relative to
the configured source root into logical names prefixed by `std/`.

Update examples using an explicit filesystem override to use:

```bash
BLORP_STD=standard_library/src
bin/blorp check --std-dir standard_library/src ...
```

The override must point at `src`, not at `standard_library`.

### 6. Update test and quality ownership

Update `scripts/test` so that:

- runtime discovery includes `standard_library/test`;
- `std-check` counts and checks only `standard_library/src`;
- doctests traverse only `standard_library/src`;
- standard-library tests remain owned by the runtime gate;
- test-only source changes do not affect embedded compiler inputs.

Update the corresponding paths in:

- `scripts/check-std-builtins`
- `scripts/premerge-gate`
- `scripts/README.md`
- Makefile security and leak test lists
- shell harness assertions
- generated artifact cleanup

Synthetic test fixtures may continue to use a temporary directory named
`std` when they are testing generic std-root behavior rather than repository
layout. Do not rename those mechanically.

### 7. Update CI, cache, benchmark, and fixture paths

Update compiler-binary cache inputs in `.github/workflows/` from
`std/**/*.brp` to `standard_library/src/**/*.brp`. Do not include
`standard_library/test` in a compiler-binary cache key unless the cached
artifact actually includes tests.

Update physical paths in:

- `.gitignore`
- `benchmarks/blorp_test_session_policy.json`
- `benchmarks/compiler_typecheck_replay`
- codegen-audit fixtures with relative imports into the old test tree
- LSP measurement scripts that enumerate the physical source root
- current developer documentation and executable examples

After reviewing the exact policy change, recompute
`REGISTERED_WORKLOADS_CONTRACT_SHA256` in
`blorp/test/test/test_session_benchmark.py`. Do not blindly copy the hash from
a failing assertion; independently calculate the canonical workload hash and
confirm that only intended physical paths changed.

### 8. Audit remaining `std/` matches

Run a repository-wide search after the migration. Preserve matches that are
logical identities, including:

- `"std/list"`, `"std/prelude"`, and similar compiler constants;
- `std/test: TestSuite` imports;
- builtin names such as `std/list.__unsafe_list_set_index`;
- package compatibility values;
- tests deliberately modeling a generic directory named `std`.

Update matches that are physical paths, including:

- paths ending in `.brp` under the former root;
- `find std`, `ROOT / "std"`, and `join(cwd, "std")`;
- `BLORP_STD=std` examples;
- current architecture and development documentation;
- relative imports that physically traverse into the old test tree.

Historical issue text may retain an old path when explicitly documenting past
state. Current commands and current-layout descriptions must be updated.

## Validation

Run the focused contracts first:

```bash
make
blorp/test/build/test_build_source_generator.sh
blorp/test/build/test_build_configuration.sh
blorp/test/build/test_scripts_test_harness.sh
python3 -m unittest blorp.test.test.test_session_benchmark
```

Verify filesystem override behavior:

```bash
env BLORP_STD=standard_library/src \
  bin/blorp check --no-format blorp/test/runtime/types/test_bool.brp

std_root="$(pwd)/standard_library/src"
bin/blorp check --no-format --std-dir "$std_root" "$std_root"
```

Verify embedding explicitly:

```bash
rg '"std/test"' blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp
! rg '"std/test/' blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp
```

Run the owning gates:

```bash
make hygiene-check
scripts/test --no-build --serial \
  compiler-blorp std-check runtime doctest cli
git diff --check
```

Inspect `git status` and remove all generated `.c`, temporary, and build
artifacts that are not established tracked outputs.

## Acceptance Criteria

- `std/` no longer exists.
- Production and test sources have separate explicit roots.
- Logical `std/*` identities and public imports are unchanged.
- The embedded compiler contains `std/test` but no `std/test/*` test modules.
- `std-check` and doctest inspect only production sources.
- Runtime discovers and executes all moved standard-library tests.
- `BLORP_STD` and `--std-dir` work with `standard_library/src`.
- LSP and package source loading retain the same logical module identities.
- Compiler cache inputs depend on production sources, not tests.
- No compatibility shim or duplicate discovery path remains.
- Required focused contracts and owning gates pass.
- Code review confirms that no physical-path replacement altered a logical
  module identity.
- The final change contains only the layout migration, required path updates,
  regenerated embedded source, tests, and current documentation.

## Review Guidance

Review this as a mechanical ownership change, but pay particular attention to
the physical/logical `std` distinction. The most dangerous failure mode is a
global path replacement that silently changes compiler identities, builtin
names, import semantics, or diagnostics. The second is leaving tests beneath
the source root through an alias or fallback, which would defeat the purpose of
the migration.
