# The borrowed-call protection walk skips most Core variants

Status: open.

## Reproduction and cause

`protect_borrowed_param_calls` in
`blorp/src/compiler/stage_09_core/perceus/borrowed.brp` rewrites calls that
consume or store a value borrowed from a parameter or match payload. It runs
before `retain_borrowed_param_aggregate_members` and ends in the same silent
`_: expr`, which returns every unlisted variant unchanged without visiting its
children. A call inside `SelectExpr`, `PreClosureDetachExpr`,
`PreClosureConcurrentExpr`, `PreClosureConcurrentlyLoopExpr`, `TailrecLoopExpr`,
`TailrecRecurExpr`, `ListHandoffExpr`, `TensorRawViewLetExpr` or a string or
tensor write is never protected, so a consuming call that receives the borrowed
value there takes the owner's reference. This is the bug class that
`d3cfec04c` fixed for loops and that the aggregate walk had for these forms.

## Proposed change

Replace the `_: expr` with explicit arms, as the aggregate walk now has: walk
each form's children, let a binder hide the owner only in its body, and list the
forms that cannot reach Perceus as leaves with a reason. Write a runtime case
under `blorp/test/runtime/memory/` for each form a user program can build, such
as a consuming call on a match payload inside a `select:` arm.
