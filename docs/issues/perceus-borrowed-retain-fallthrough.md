# Perceus borrowed-payload retain walk skips most Core variants

Status: open.

## Reproduction and cause

`retain_borrowed_param_aggregate_members` in
`blorp/src/compiler/stage_09_core/perceus/borrowed.brp` adds a retain when a
value borrowed from a parameter, such as a match payload, is stored into a
record, tuple, list, dictionary or union built inside the expression. It
matches the forms it rewrites and ends in a silent `_: expr`, which returns
every other variant unchanged without visiting its children.

That is how `for` loops were missed. A borrowed `Option` payload stored into a
record inside a `for` body shared the owner's reference, and each overwritten
record freed it: a heap-use-after-free in user programs, and an exit-133 crash
without a sanitizer. Commit `d3cfec04c` added the `For*Expr` variants and left
the fallthrough in place.

About 50 variants still reach it, among them: `BinaryExpr`, `LogicalExpr`,
`UnaryExpr`, `CastExpr`, `BoxExpr`, `UnboxExpr`, `FieldExpr`, `TupleFieldExpr`,
`UnionReuseConstructExpr`, `ListSetExpr`, `ListHandoff*Expr`, `DictExpr`,
`TailrecLoopExpr`, `TensorRawViewLetExpr`, `DebugBlockExpr`, the
`Concurrent*` and `PreClosure*` forms, `SelectExpr`, `DetachExpr`,
`RawMatchExpr`, `SemanticMatchExpr` and `LambdaExpr`. Some are leaves, some
cannot reach Perceus, and some may build or store an aggregate from a borrowed
value. Today nothing records which is which.

A probe compiled under `--sanitize` already passes for `while` loops, a
self tail call, closure capture, a `for` loop inside an `if`, and a list
literal in a loop. These show that some shapes are safe, not that the walk is
complete.

## Proposed change

Replace the `_: expr` arm with explicit arms, as `core_expr_source_loc` in
`stage_09_core/ir.brp` lists every variant. Each variant then gets a decision
the compiler enforces through exhaustiveness:

- leaves and forms that hold no borrowed value are returned unchanged, in one
  named alternation;
- forms with child expressions are walked, with any binder hiding the borrowed
  owner only in its own scope, as `retain_borrowed_param_loop_body` does for
  loops;
- forms that cannot reach Perceus (`RawMatchExpr`, `SemanticMatchExpr`, the
  pre-closure forms) are grouped and documented as such. If one does reach this
  walk, it should fail loudly rather than pass through.

A new Core variant then fails to compile here until someone decides how it
treats borrowed values.

## Acceptance

For every variant that is newly walked, add a `test_core_perceus.brp` case and,
where a user program can build that shape, a runtime case under
`blorp/test/runtime/memory/` that fails before the change. Self-compile C
should stay identical, or every difference should be explained by a retain the
old walk missed. Run `test_core_perceus.brp`, `compiler-core-sanitize`, `leak`
and `compiler-blorp`, one compiled binary at a time.
