# Eliminate Exact Callable Recovery From `Env`

**Status:** Implemented

**Dependencies:** Issue 38 and the retained-call-resolution prerequisite

## Objective

Stop maintaining an exact callable-ID index in `Env` when no production reader
needs it. Do not replace unused lookup machinery with a declaration-catalog
authority.

Source-name candidate discovery remains in `Env` for Issue 40. This issue only
owns post-resolution exact recovery and the exact-ID index that supported it.

## Prerequisite Result

Call resolution retains the selected candidate's bound type parameters and
debug-only status directly in `ResolvedCallInfo`. Call checking therefore uses
the candidate it already selected instead of rescanning overload, UFCS,
function, and implementation storage by integer definition ID. Trait UFCS also
reuses its already-selected implementation metadata instead of inferring the
receiver and resolving the implementation a second time.

That prerequisite deleted the broad exact-metadata scan helpers and reduced the
three-pair Phase 01-06 self-check median from 457,921,505,497 to
449,083,980,073 retired instructions (1.93%), while median wall time fell from
26.89 to 26.42 seconds.

## Remaining Consumer Inventory

| Consumer | Lookup before prerequisite | Result |
| --- | --- | --- |
| Call bound checks | definition ID across overloads, UFCS, scopes, and implementations | reads `ResolvedCallInfo.bound_type_params` |
| Debug-only call checks | definition ID across scopes, overloads, UFCS, and implementations | reads `ResolvedCallInfo.debug_only` |
| Function values and callbacks | repeated the same metadata recovery after candidate selection | retain the selected candidate metadata |
| Header completion | source name plus definition ID in that name's candidate bucket | remains source-name discovery for Issue 40 |
| `env_find_func_by_def_id` | no production caller | deleted with its test-only index |

The inventory found no production exact-ID `Env` reader. Building a callable
authority would add a second representation without serving a consumer.

## Implemented Change

1. Removed `Scope.function_indexes_by_callable_id` and its write on every
   function insertion.
2. Removed `scope_find_func_by_def_id` and `env_find_func_by_def_id`.
3. Removed the test that existed only to exercise that obsolete API.
4. Kept `env_find_func_named_by_def_id`: it searches an already-selected source
   name's candidates and belongs to Issue 40, not exact identity recovery.
5. Added a structural boundary check preventing the exact index or reader from
   returning.

## Non-Goals

- Do not migrate source-name candidates or overload selection.
- Do not change lexical function shadowing.
- Do not migrate trait or implementation declaration storage.
- Do not redesign callable IDs.
- Do not add a catalog table with no production reader.

## Acceptance Criteria

- `Env` has no exact callable-ID index or exact function reader.
- Resolved call metadata remains attached to the selected candidate.
- Function-value, callback, generic-call, debug-only, trait/implementation,
  foreign, builtin, constructor, closure, and CTFE behavior is unchanged.
- Source-name candidate lookup remains explicit and isolated for Issue 40.
- No dual read or compatibility adapter remains.
- Focused compiler checks pass.
- Three alternating Phase 01-06 self-check pairs retire fewer median
  instructions than the prerequisite parent without a clear latency regression.

## Verification

Run the structural declaration boundary check, the `Env`, inference, typecheck,
typed-AST JSON, CTFE, and Core-lowering suites selected by
`scripts/compiler-check --changed`. Build isolated parent and candidate
binaries, warm each once, and run three alternating `/usr/bin/time -lp`
self-check pairs.

The final deletion produced:

```text
control:   26.36s / 449,186,079,055 instructions
candidate: 25.67s / 436,726,344,400 instructions
control:   26.48s / 449,368,371,753 instructions
candidate: 25.96s / 436,450,867,149 instructions
control:   26.71s / 449,164,767,446 instructions
candidate: 26.08s / 436,386,241,483 instructions
```

Median retired instructions fell by 12,735,211,906 (2.84%), from
449,186,079,055 to 436,450,867,149. Median wall time fell from 26.48 to
25.96 seconds. Combined with the prerequisite, median retired instructions are
4.69% below the original Issue 39 baseline.
