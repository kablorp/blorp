# A task closure capture stored in an aggregate is not retained

Status: open.

## Reproduction and cause

A function parameter that a `detach`, `concurrent:` binding or
`for ... concurrently` body captures and stores into a record frees the
caller's string when the record dies, so the caller reads freed memory
afterwards. A probe under `--sanitize` reports a heap-use-after-free:

```blorp
record TextHolder {
    text: String
}

pure func holder_length(holder: TextHolder) -> Int:
    holder.text.length()

func detached_length(name: String) -> Int:
    detach holder_length({ text = name })
    0
```

The same function with `concurrent:` (`x = holder_length({ text = name })`) or
a `for item in items concurrently(limit: 2):` body fails the same way. A match
payload captured the same way is correct, because
`retain_borrowed_param_aggregate_members` in
`stage_09_core/perceus/borrowed.brp` now walks task bodies.

A task closure takes its own reference to a capture after Perceus
(`closure.brp`). The parameter does not become a borrowed owner, so no walk
retains the aggregate's store (the Core after Perceus has no `DupExpr` in the
task body). A lambda body avoids this because
`normalize_lambda_expr` makes its captures the owners of its own region; task
bodies have no such region, and `normalize_borrowed_child` leaves them as is.

## Proposed change

Give a task body the same treatment as a lambda body: derive its captures and
normalize the body with them as owners. Add `detach`, `concurrent:` and
`concurrently` parameter cases to
`blorp/test/test_runtime/test_memory/test_borrowed_payload_concurrency_ownership.brp`.

## A global stored the same way (found while fixing sequential `for` loops)

`normalize_borrowed_boundaries` now walks the nine sequential `for` loop nodes
in storage mode, which fixed a managed global stored in a record inside an
ordinary `for` loop. The task and loop nodes that fall through its catch-all
arm (`PreClosureConcurrentlyLoopExpr`, `ConcurrentlyLoopExpr`,
`PreClosureDetachExpr`, `SelectExpr` and the `Tailrec*Loop` nodes) still get no
retain for a global stored in an aggregate. This probe stores one in a
`for ... concurrently` body:

```blorp
record Box {
    name: String,
    count: Int
}

GLOBAL_NAME: String = "shared" + "x"

func record_size(box: Box) -> Void:
    print(box.name.length())

func concurrently_store(items: List[Int]) -> Void:
    for item in items concurrently(limit: 2):
        box: Box = {name = GLOBAL_NAME, count = item}
        record_size(box)
```

In the generated C each task takes one reference to the global for its closure
capture (`blorp_retain(GLOBAL_NAME)` into the closure env), builds the record
with `brp_ty1_make(GLOBAL_NAME, ...)` and no retain, then releases the record
(`blorp_release(box)`, which drops the global's reference) and the capture
(`blorp_release_arc_only(GLOBAL_NAME)`). That is one retain against two
releases, so the count falls by one per task. The probe does not crash because
the constant-folded global is a static string literal that ignores reference
counts; a global built at start-up would free while still in use.

`select` and the tailrec loop nodes have not been probed, so they are unverified.
They share the catch-all arm and may need the same treatment. The fix belongs
with the proposed change above: treat a task body as a region whose captures
are owners, and give the `select` and tailrec nodes explicit arms.
