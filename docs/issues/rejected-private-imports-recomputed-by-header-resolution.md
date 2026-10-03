# Header resolution recomputes which imports were rejected as private

Status: open.

An unqualified type name that no module declares is reported as the import's
own error when the module selectively imports it from a module where it is
`private` (`'Hidden' is private in module 'dep' and cannot be imported`),
instead of as an unknown type. The header phase has no record of the binder's
decision, so `program_rejected_private_import`
(`blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`) re-runs the
import selection over the program's import declarations and asks
`imported_symbol_is_private`, the same test the binder uses, so the two cannot
disagree on what "private" means. It still repeats the work for every unknown
name.

## Proposed fix

The replacement resolution stage records each rejected private import on the
bound module as it makes the decision: local name to (module path, original
name). Header resolution then reads that record, with no import re-selection and
no second call to the private-name test. The unknown-type path keeps its
current behaviour for every name without a record.
