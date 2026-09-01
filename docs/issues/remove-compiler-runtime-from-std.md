# Remove Compiler Runtime Sources From `std`

**Status:** Complete

## Issue Summary

Remove `std/compiler_runtime.brp`. Put the shared `RuntimeSources` value type in
`blorp/src/lib/`, put the compiler-executable-specific embedded-source provider
in `blorp/src/compiler/`, and replace the current nullary pure API with an
explicitly impure load boundary.

This is a focused ownership and semantics cleanup. Preserve the generated C
provider, compiler artifact contents, runtime-object caching, compile/run/test
behavior, and build latency. Do not redesign the native runtime or introduce a
generic dependency-injection framework.

## Context

Production code currently imports a bare module named `compiler_runtime`:

```blorp
import:
	compiler_runtime: RuntimeSources
```

That import resolves to `std/compiler_runtime.brp`, not a module under
`blorp/src/`. The module currently contains:

```blorp
private pure func compiler_runtime_source_raw() -> String:
	builtin("blorp_compiler_runtime_source")

private pure func compiler_runtime_declarations_raw() -> String:
	builtin("blorp_compiler_runtime_decl")

record RuntimeSources {
	runtime: String,
	declarations: String
}

pure func runtime_sources() -> RuntimeSources:
	{
		runtime = compiler_runtime_source_raw(),
		declarations = compiler_runtime_declarations_raw()
	}
```

The build separately generates
`blorp/build/_build/blorp-cli/runtime_sources.c`. That C translation unit embeds
the exact contents of:

- `blorp/src/lib/runtime/native/minicoro.h`;
- `blorp/src/lib/runtime/native/runtime.c`; and
- `blorp/src/lib/runtime/native/runtime_decl.c`.

The compiler executable links that generated provider with
`BLORP_COMPILER_RUNTIME_SOURCES=1`. Native builtins return the embedded strings
to the Blorp layer so compile, run, and test operations can write standalone C
artifacts and populate the runtime-object cache.

## Problems

### Compiler Infrastructure Is Shipped As Standard Library

`compiler_runtime` is not a user-facing portable library. It is an assembly
boundary for the Blorp compiler executable. Its presence in `std/`:

- exposes a compiler implementation detail as a bare user import;
- causes it to be included in the generated embedded-standard-library map;
- makes its actual owner difficult to discover; and
- conflates a shared internal data type with a compiler-only host provider.

Ordinary Blorp programs currently receive empty strings from these builtins
when the executable was not compiled with
`BLORP_COMPILER_RUNTIME_SOURCES=1`. That fallback does not make the API a
standard-library facility.

### The Nullary Pure API Hides Ambient Input

`runtime_sources()` and its two private builtin wrappers are pure functions
that take no arguments. They do not derive a result from explicit inputs; they
read data selected and linked by the host build.

Representing that operation as pure is misleading. A nullary pure function is
normally a constant with function-call ceremony. Here it is worse: it disguises
an executable assembly dependency as an ordinary deterministic calculation.

Do not preserve the shape by merely moving the existing file.

## Target Ownership

Use two precise modules:

```text
blorp/src/
  main.brp
  compiler/
    runtime_source_provider.brp
  lib/
    runtime_sources.brp
```

### `lib/runtime_sources.brp`

This module owns only the shared data contract:

```blorp
record RuntimeSources {
	runtime: String,
	declarations: String
}
```

Do not add passthrough constructors, getters, setters, or a nullary
`runtime_sources()` helper. Callers constructing fixture values should use the
record literal directly.

The record belongs in `lib` because it is consumed by multiple owners,
including compiler command handling, run effects, host-C compilation, runtime
caching, and test execution.

### `compiler/runtime_source_provider.brp`

This module owns access to the compiler executable's linked runtime data. It
should:

- import `RuntimeSources` from `../lib/runtime_sources`;
- define the two required native builtin boundaries;
- expose one narrowly named operation such as
  `load_compiler_runtime_sources()`; and
- build and return the `RuntimeSources` record.

The load operation and its builtin wrappers must be impure:

```blorp
private func embedded_runtime_source() -> String:
	builtin("blorp_compiler_runtime_source")

private func embedded_runtime_declarations() -> String:
	builtin("blorp_compiler_runtime_decl")

func load_compiler_runtime_sources() -> RuntimeSources:
	{
		runtime = embedded_runtime_source(),
		declarations = embedded_runtime_declarations()
	}
```

The precise names may be improved during implementation, but the semantics may
not regress to `pure`. A concise comment should explain that this is an ambient
build-linked resource and therefore intentionally effectful.

The aggregation function is not a pointless passthrough: it is the single
boundary that converts two native provider calls into the shared typed value.
Keep the native builtin names private.

### `main.brp`

`blorp/src/main.brp` is the sole executable composition root. It may import the
compiler provider and pass the returned shared value to compilation and run
effects.

Replace imports and calls along these lines:

```blorp
import:
	compiler/runtime_source_provider: load_compiler_runtime_sources
```

Existing `runtime_sources()` calls in `main.brp` should become explicit loads at
the executable assembly boundary. Do not make command directories import the
compiler provider.

If a straightforward local refactor allows one load to be threaded through the
selected command path without broad signature churn, prefer that. Otherwise,
one load at each mutually exclusive compile/run/test assembly path is
acceptable. Do not introduce global mutable state or a cache merely to avoid a
second theoretical call.

## Dependency Rules

After the change:

- `main.brp` may import `compiler/runtime_source_provider` and
  `lib/runtime_sources`;
- `compiler/` modules may import `lib/runtime_sources`;
- `run`, `test`, and other command owners may import only the shared
  `lib/runtime_sources` contract, never the compiler provider;
- `lib` modules may import their sibling `runtime_sources` module;
- `std/` must contain no compiler runtime source provider or `RuntimeSources`
  declaration; and
- ordinary bare imports must not resolve `compiler_runtime`.

This respects the rule that `main.brp` is the only arbitrary composition root.

## Exact Source Changes

### Delete

- `std/compiler_runtime.brp`

Do not leave a forwarding module, deprecation shim, empty placeholder, or alias
under `std/`.

### Add

- `blorp/src/lib/runtime_sources.brp`
- `blorp/src/compiler/runtime_source_provider.brp`

### Update Imports

At the time this issue was written, production `RuntimeSources` imports exist
in:

- `blorp/src/compiler/command.brp`;
- `blorp/src/lib/host_c.brp`;
- `blorp/src/lib/run_effect.brp`;
- `blorp/src/lib/runtime_cache.brp`; and
- `blorp/src/main.brp`.

Test imports exist in:

- `blorp/test/compiler/test_command.brp`;
- `blorp/test/run/test_command.brp`;
- `blorp/test/test/test_effect.brp`;
- `blorp/test/lib/test_host_c.brp`;
- `blorp/test/lib/test_program_runner.brp`; and
- `blorp/test/lib/test_runtime_cache.brp`.

Re-run a repository-wide search before editing because concurrent work may have
added consumers:

```bash
rg -n 'compiler_runtime|RuntimeSources|runtime_sources\(\)' \
  blorp/src blorp/test std pkg --glob '*.brp'
```

Use owner-relative imports. Do not replace the bare standard import with a new
global alias or add the internal module to another global search path.

## Test Fixture Cleanup

Some tests currently define their own nullary pure `runtime_sources()` helpers.
Because this issue already touches those imports, do not perpetuate the same
pattern in the migrated tests.

For fixed fixture data, use either:

- an explicit `RuntimeSources` record literal at the call site; or
- a clearly named immutable fixture value when multiple tests share exactly
  the same value.

Do not replace the helpers with differently named passthrough getters or
constructors. Do not expand this issue into a repository-wide nullary-pure
cleanup outside the `RuntimeSources` call sites.

## Generated Sources And Build Inputs

`blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp` is generated from the
contents of `std/`. Regenerate it through the existing build generator after
deleting `std/compiler_runtime.brp`; do not hand-edit the embedded module map.

The regenerated file must no longer contain:

- the module identity `std/compiler_runtime`;
- the `RuntimeSources` record; or
- either compiler-runtime builtin wrapper.

Do not remove or rename:

- the `embedded-runtime-c` generator mode;
- `blorp/build/_build/blorp-cli/runtime_sources.c` as a build product;
- `blorp_compiler_runtime_source_data`;
- `blorp_compiler_runtime_decl_data`;
- `blorp_compiler_runtime_source`;
- `blorp_compiler_runtime_decl`; or
- `BLORP_COMPILER_RUNTIME_SOURCES=1`.

Those are the native implementation of the new compiler-owned provider, not
the misplaced standard-library API.

Update build input and source-layout tests so they assert the new ownership.
Generated files under `blorp/build/_build/` remain ignored build products and
must not be committed.

## Manifest Updates

Update the relevant checked-in ownership metadata:

1. Register `blorp/src/compiler/runtime_source_provider.brp` in
   `blorp/test/compiler/compiler_test_ownership.json` with focused provider or
   compile-command coverage and the appropriate broad gate.
2. Add `lib/runtime_sources.brp` to `blorp/source_ownership.json` with its real
   multi-owner consumers.
3. Remove any ownership or standard-library inventory entry for
   `std/compiler_runtime.brp`.
4. Update current architecture or development documentation that presents all
   of `std/` as user-facing portable library code if it needs a path-specific
   correction.

Do not add an exception that blesses the old placement.

## TDD Sequence

### 1. Add Failing Ownership Tests

Before moving implementation, add checks that fail while
`std/compiler_runtime.brp` still exists. Cover:

- the compiler runtime provider is absent from `std/`;
- `std/compiler_runtime` is absent from the generated embedded-standard-module
  inventory;
- the shared `RuntimeSources` contract exists under `blorp/src/lib/`;
- the native provider exists under `blorp/src/compiler/`; and
- the ownership manifests register both new modules correctly.

Use the existing build/layout test owners rather than creating a new test
framework.

### 2. Add Provider Behavior Coverage

Add or adapt focused coverage proving the installed compiler's provider returns
nonempty runtime and declaration strings and that they are accepted by the
existing compile/run cache paths.

Do not compare the entire embedded runtime as a giant golden string. Assert
stable identifying content and nonempty values; the build-source-generator
suite already verifies byte-for-byte generated provider contents against the
native input files.

### 3. Move The Contract And Provider

Add the two target modules, update imports, and delete the standard module in
one working change. There must be only one `RuntimeSources` declaration and one
native provider authority at every commit intended as a merge point.

### 4. Remove The Nullary Pure Pattern

Make provider reads explicitly impure, replace the public pure getter, and
remove touched test fixture getters. Verify no relevant nullary pure function
remains:

```bash
rg -n 'pure func .*\(\).*RuntimeSources|pure func runtime_sources\(\)' \
  blorp/src blorp/test std pkg --glob '*.brp'
```

### 5. Regenerate And Verify

Run `make` to regenerate embedded std and rebuild the self-hosted CLI. Confirm
the standard-module inventory no longer contains `compiler_runtime` and the
compiler executable still embeds the native runtime data.

## Required Verification

Run at minimum:

```bash
make
python3 scripts/check-blorp-layout
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  blorp/test/build/test_blorp_source_layout.py \
  blorp/test/compiler/build/test_compiler_check.py
blorp/test/build/test_build_source_generator.sh
blorp/test/build/test_build_configuration.sh
scripts/compiler-check --changed
scripts/test compiler-blorp
scripts/test runtime
scripts/test cli
```

Run the focused host/runtime-cache and command suites selected by the ownership
manifest, including the current equivalents of:

```bash
bin/blorp test blorp/test/compiler/test_command.brp
bin/blorp test blorp/test/run/test_command.brp
bin/blorp test blorp/test/test/test_effect.brp
bin/blorp test blorp/test/lib/test_host_c.brp
bin/blorp test blorp/test/lib/test_runtime_cache.brp
```

Also verify directly:

1. `bin/blorp compile --no-format` still writes a valid standalone C artifact.
2. A representative compile artifact contains the same embedded runtime content
   as before this refactor.
3. `bin/blorp test --warmup-only` still populates the runtime cache.
4. A normal source file cannot import bare `compiler_runtime` from `std`.
5. No checked-in generated `.c` artifact is left in the repository.

## Performance Requirement

This issue does not seek a performance improvement, but it must not introduce a
clear latency regression.

- Do not read or construct the large embedded runtime strings more often along
  a single command path than the current implementation.
- Do not add a second generated provider or duplicate the embedded bytes.
- Confirm the changed-source self-host build remains within normal noise.
- Confirm the no-op build remains fast.
- If threading one loaded value is simpler than repeated loads, thread the
  immutable `RuntimeSources` value explicitly; do not add global mutable
  caching.

## Explicit Non-Goals

This issue does not:

- change the contents or ABI of the native runtime;
- rename the native C symbols or compiler builtins;
- redesign runtime-object caching;
- move the native runtime out of `blorp/src/lib/runtime/native/`;
- add compiler runtime source access to ordinary programs;
- create a public standard-library replacement API;
- add compatibility for the old `compiler_runtime` import;
- perform a repository-wide cleanup of all nullary pure functions;
- introduce getters or setters for `RuntimeSources`;
- introduce a service locator, global mutable cache, or generic provider
  framework; or
- pin a new bootstrap compiler unless an actual language change is discovered,
  which should be treated as a separate blocker.

## Acceptance Criteria

- [x] `std/compiler_runtime.brp` is deleted without a compatibility shim.
- [x] Bare `compiler_runtime` no longer resolves as a standard-library import.
- [x] `RuntimeSources` has exactly one declaration, under
      `blorp/src/lib/runtime_sources.brp`.
- [x] The compiler-only native provider lives under
      `blorp/src/compiler/runtime_source_provider.brp`.
- [x] Provider reads are explicitly impure and named as loads of build-linked
      data.
- [x] No production nullary pure `runtime_sources()` API remains.
- [x] Touched `RuntimeSources` test fixtures do not use nullary pure getter or
      constructor helpers.
- [x] Main remains the sole arbitrary composition root.
- [x] Run, test, and other command owners import only the shared lib contract,
      not the compiler provider.
- [x] The generated embedded-standard-library inventory contains no
      `std/compiler_runtime` entry.
- [x] The generated C provider and native builtin symbols remain singular and
      unchanged.
- [x] Compiler artifacts and runtime-cache warmup still receive nonempty,
      correct runtime source and declaration strings.
- [x] Ownership manifests, build tests, and current architecture documentation
      describe the new locations.
- [x] Focused suites, compiler suites, runtime tests, and CLI tests pass.
- [x] Changed-source and no-op builds show no clear regression.
- [x] No generated C artifact or ignored build output is committed.

## Agent Handoff Notes

Start by reading:

- `docs/LEARN_BLORP_IN_Y_MINUTES.md`;
- `std/compiler_runtime.brp`;
- `blorp/src/main.brp` around runtime/run/test configuration;
- `blorp/src/lib/host_c.brp`;
- `blorp/src/lib/run_effect.brp`;
- `blorp/src/lib/runtime_cache.brp`;
- `blorp/tool/generate_build_sources.brp`;
- the `BLORP_CLI_RUNTIME_*` portion of `Makefile`; and
- the matching build, command, host-C, and runtime-cache tests.

Before editing, report the exact production and test consumer inventory and
confirm which build step generates `runtime_sources.c`. During implementation,
keep the move mechanical and ask for guidance if removing the std module would
require a new module-resolution exception, a compatibility shim, or a bootstrap
language change; none of those is authorized by this issue.
