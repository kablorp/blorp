# Index Core-Lowering Function Deduplication

**Status:** Proposed; implementation and measurement ready

**Current state:** `flatten.deduplicate_functions` can search all declarations
for an implementation while processing each function signature and also keeps
an ordered seen-name list.
**Next action:** Add forward-declaration-first and same-name/different-ID tests,
precompute implemented names once, and perform one stable deduplication pass.
**Read first:** `blorp/src/compiler/stage_08_core_lower/flatten.brp` and
`blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp`.
**Fast loop:** Run the focused flatten suite plus a proposed many-declaration
production-pass fixture.
**Decision:** Preserve the exact duplicate winner and declaration order; ask
before changing the flattened Core identity model.

## Objective

Replace declaration-wide repeated searches with one index build and one stable
pass, making the work linear expected time in declarations.

## Proposed Shape

Build invocation-local indexes from the exact string key used by the current
comparison:

```text
implemented function name -> true
seen emitted function name -> true
```

Then walk declarations in current order, admitting or suppressing a function
according to those indexes. Retain an ordered output list; never reconstruct
declarations from dictionary iteration. Do not strengthen the current key to
module, `def_id`, or another nominal identity as part of this optimization.

## Invariants And Tests

- Preserve the current name-only winner rule: an implementation wins over a
  forward declaration; otherwise the first declaration wins.
- Cover same-name/different-`def_id` inputs explicitly so this refactor does not
  silently strengthen identity.
- Preserve source modules, methods, globals, and all non-function declarations.
- Cover duplicates before/after implementations, same spelling with distinct
  identity, empty programs, and many interleaved declarations.
- Preserve diagnostics and flattened Core ordering exactly.
- Do not combine this with general Core declaration indexing.

## Feedback Loop

Extend `compiler_core_flatten_profile` with forward-declaration-first and
implementation-first orders; the retained fixture's implementation-first shape
mostly short-circuits the expensive rescan. Vary declarations, duplicate ratio,
and implementation placement. Record declarations visited, full-declaration
fallback scans, membership probes, allocations/releases, retired instructions,
elapsed time, and ordered Core hash. `ImplDecl` is passed through untouched, so
method count is not an axis for this function.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_08_core_lower/test_core_flatten.brp
scripts/compiler-check --changed
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept when full-declaration rescans fall to zero after one index build, the
wide mixed fixture improves instructions or allocations by at least 10%, the
small path remains within 2%, and Core/C output is identical. Reject if the
name-only winner rule or ordering changes, or the new index is rebuilt for each
function.
