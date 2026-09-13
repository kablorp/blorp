# Avoid Per-Callable Registry Copies During Core Graph Preparation

**Status:** Investigate ownership, then optimize the proven copy site

**Owner:** Stage 08 Core lowering/graph preparation

**Target:** `register_callable_name` in `blorp/src/compiler/stage_08_core_lower/graph_prepare.brp`

## Why

Each callable registration gets a dictionary from `by_module`, inserts into
it, then replaces the same list slot. Native sampling of a many-function
fixture landed in `register_callable_name`, `blorp_dict_cow`, and
`blorp_dict_copy`. Core lowering grew about 7.9x over a 4x fixture-size
increase. The likely repeated dictionary copy is actionable, but the exact
ownership cause and any outer-list copy still need direct measurement.

## What to inspect and change

- Trace ownership through `by_module.get`, `by_callable.set`,
  `by_module.set`, `register_decl_callable_names`, and
  `register_program_callable_names`. Inspect generated C retains/releases and
  count copied dictionary entries and outer-list elements separately.
- If lookup retains the stored dictionary while the list still owns it,
  consider building one module's dictionary through a uniquely owned local
  accumulator and storing it once when that module is complete. If the outer
  list is also repeatedly copied, address that within this registry boundary.
- Preserve `ModuleId`/callable-ID identity, module prefix escaping, source and
  UFCS names, declaration/method/private traversal order, and `None` behavior
  when a module slot is absent. Do not replace exact keys with string names or
  weaken value semantics to obtain mutation.
- `Dict.with_capacity` may reduce rehashing, but is not a solution if the
  dictionary is copied on every insertion. Compare with the existing
  module-range batching pattern in `stage_06_typecheck/headers/callable_headers.brp`.

## Fast feedback loop

Use `blorp/test/compiler/stage_08_core_lower/test_core_lower.brp` for identity
and error-path tests. Add an isolated graph-preparation benchmark with 1/8/32
modules and 4,096/8,192/16,384 total callables, holding the per-function body
shape constant. Construct typed graph inputs outside timing; instrument the
private registry path without widening its production visibility. Report
registered callables, dictionary and list copy counts/bytes, allocations,
checksum, and elapsed time. This short whole-pipeline smoke check includes
lowering and emits C but does not invoke a C compiler:

```bash
bin/blorp compile --no-format --no-embed-runtime --time-phases \
  -o /tmp/blorp-registry-smoke.c examples/hello.brp
```

Use a deterministic, retained fixture generator in `benchmarks/` for the
scaling measurement; avoid one giant function body, which separately exhausts
the current Core mapper stack.
Run five warm samples. Only after the direct copy source is known, compare
full C-emission `core_lowering` timings for that fixture and self-compilation.

## Acceptance, rejection, and rollback

- A work-counter regression fails before and passes after the change;
  functional tests remain green for multiple modules, impl and private
  methods, exact names/IDs, and missing-slot behavior.
- Per-callable dictionary-entry copying is eliminated or bounded by amortized
  linear construction; separate list-copy measurements are accounted for.
  Isolated copied-entry work scales by at most 2.5x per doubling at the two
  largest sizes, rather than with the square of callables in one module.
- Direct median time/instructions improve, with no repeatable Core-lowering
  or self-emission regression; focused Core, leak/sanitizer, and compiler gates
  pass.
- Reject capacity-only changes that leave copy counts quadratic. Roll back
  if uniqueness assumptions fail, identities change, or large-module memory
  grows materially without a compensating measured speedup.

See [the developer guide](../../DEVELOPMENT.md) for build and test commands.
