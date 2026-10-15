# Blorp 2 checker re-cut, 2026-10-15

`blorp_2/src/check/` is cut by data flow instead of by size. The 13 modules stay 13, but each is one phase or one
product and imports only earlier ones: `model`, `errors`, then `declarations`, `namespace`, `recursion`, then
`signatures`, `callables`, `inference`, `constructors`, `expressions`, `bodies`, `check`, with `render` reading
`check`'s result. Every top-level declaration (392) moved unchanged. Emitted C and every e2e diagnostic are unchanged.

## What changed

| commit | change |
| --- | --- |
| `64fc44998` | `types` to `declarations` (rename) |
| `5b579efd3` | `imports` to `namespace` (rename) |
| `8b6364a8e` | `builtins` into `signatures` |
| `9d0e40cef` | `calls` into `methods`, renamed `callables` |
| `c2453f7c7` | `inference` extracted from `values` (64 declarations) |
| `d748aa91b` | `constructors` extracted from `values` (25 declarations) |
| `8a9a21a69` | `values` renamed `expressions`; its suite split |
| this commit | README and ROADMAP sentences |

Import ranks (longest chain of checker imports below a module): `model` 0; `errors` 1; `declarations`,
`namespace`, `recursion` 2; `signatures` 3; `callables` 4; `inference` 5; `constructors` 6; `expressions` 7;
`bodies` 8; `check` 9; `render` 10. The import graph is acyclic and every edge points to a lower rank.
`bodies` imports `recursion` for `check_execution`; `recursion` is a leaf analysis over `model` and `errors`.

## Output identity

Baseline: `ba57e368a`, `blorp_2/` exported with `git archive`, compiled with the same `bin/blorp` (FRESH, commit
`ba57e368a`'s predecessor build) and `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Compiler binary SHA-256
`8988804284baec8514bd944ef68f8b20eb3bfc446562fd70efd4f2ac701d9b48`. Candidate: the series, binary SHA-256
`5b0d196647581942fe1aaa79b8e93fdbc2d095d030c0f42a58b77bce64578f8f`.

All 334 `.brp` fixtures under `blorp_2/test/e2e/fixtures`, both compilers run from the same working directory
(allocation counts depend on the directory): 299 compile and 35 are rejected. Exit status, stdout, stderr (which
carries the `BLORP_LEAK_CHECK=strict` allocation counts) and generated C are byte-identical in every case (0
differences). `make -C blorp_2 test`: 3,092 passes, 0 failures, `E2e cases: 336 passed, 0 failed`. Unit, runtime and
grammar suites: 2,299 passes, the same set of passing test names as the baseline.

## Pure moves

Per commit, a script parses `blorp_2/src/check/*.brp` into top-level declarations and compares the multiset of
declaration texts (comments and bodies included) before and after, ignoring a leading `private `. Across the series
the multiset is equal except for one comment: `check/model.brp` named `plan_record_update` as living in
`values.brp`; it now says `constructors.brp`. The only other text that changes in `check/*.brp` is the module
docstring and the import block of each module whose contents or imports moved.

## Declarations that lost `private` (55)

Moving declarations across modules needs a public surface. 53 were planned from the identifier scan. Two more are
forced because the host rejects field access on a private type from another module, although no other module names
the type: `InferenceSlotUpdate` and `PlannedRecordField` (both read in `expressions`). `InferenceVariableId`,
`InferenceParameterConstraint` and `RecordOrigin` are not named or read elsewhere, so they stay private.

From `inference` (40): `CallResultContext, ConstraintOrigin, ExpectedValue, InferenceEquality, InferencePublication,
InferenceReadiness, InferenceRelation, InferenceSlot, InferenceSlotUpdate, InferenceStep, InferenceType, InferenceUse,
InferenceVariableState, PendingBase, PendingCall, PendingOperation, PendingOperations, PendingRecordField,
PendingRetainedField, PendingStep, PendingValue, PendingVariantContract, admit_call_parameters, admit_call_type,
apply_type_hint, call_argument_constraint, call_argument_hints, call_inference_ready, inference_child,
inference_complete, inference_head, inference_shape, inference_type, inspect_inference_equality, pending_arguments,
pending_type, publish_inference_type, publish_pending_call, record_argument_origin, validate_complete_arguments`.

From `constructors` (15): `CallPlacement, PlannedBase, PlannedRecordField, PlannedRecordFields, RecordOccurrence,
finish_pending_record, finish_pending_variant, plan_record_literal, plan_record_update, plan_variant,
record_argument_hints, record_occurrence, resolve_record_field, validate_record_fields, validate_variant_fields`.

Follow-ups, not done here (each edits a function or a visibility the move did not touch):
- Extracting `elaborate_value`'s constraint loop (671 formatted lines) into `inference` would narrow this surface
  and shrink the largest function in the checker.
- Seven public names are now used only inside their own module: `Caller`, `ReceiverContract`, `receiver_contract`,
  `start_inference`, `inferred_substitution`, `infer_arguments` (all `callables`) and `validate_builtin_body`
  (`signatures`). They were public because another checker module imported them; that module is gone.

## Size

Production lines, formatted copies (`bin/blorp format`), non-blank and non-comment:

| module | before | after |
| --- | --- | --- |
| `declarations` (was `types`) | 772 | 772 |
| `namespace` (was `imports`) | 69 | 69 |
| `signatures` (+ `builtins`) | 274 + 285 | 543 |
| `callables` (`methods` + `calls`) | 367 + 319 | 661 |
| `inference` | (in `values`) | 1,529 |
| `constructors` | (in `values`) | 630 |
| `expressions` (was `values`) | 3,608 | 1,568 |
| `bodies` | 657 | 651 |
| `check`, `model`, `errors`, `recursion`, `render` | 81, 389, 228, 296, 1,160 | unchanged |
| total | 8,505 | 8,577 |

The import blocks went from 511 to 575 lines (+64, 0.8% of production lines); module docstrings account for the
other +8. The brief expected import lines to fall; they cannot while `values` is cut into three modules, because
`expressions` imports 37 declarations from `inference` and 14 from `constructors`. The shape that would have let
them fall (everything but `inference` folded into `bodies`) leaves one 2,600-line module, which is the failure this
change removes. The measurement overrides the expectation.

## Deviations from the moves as planned

- **Two promotions beyond the plan** (above), forced by the host's rule on field access to private types.
- **`test_signatures` calls `check` through `input.check`**, which is a one-line wrapper of the real `check`; the
  merged suite imports one `check`, not two.
- **Import blocks.** `inference`, `constructors`, `expressions` and the merged `signatures` and `callables` get import
  blocks generated from the symbols each module uses; rows for other modules keep their original text. `bodies`,
  `check` and the tests that import a moved module change path tokens only (`values` items that moved to
  `constructors` are re-pointed in `bodies`).

## Tooling

The scripts that produced and checked the moves (declaration-multiset identity, path-keyed import graph with the
opaque-type check, fixture comparison) are not retained: they live in the author's session scratchpad, under `rc/`
and `proof.sh`, because a standing harness would be a new mechanism that needs its own approval.
