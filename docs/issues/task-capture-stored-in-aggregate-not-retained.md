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
`blorp/test/runtime/memory/test_borrowed_payload_concurrency_ownership.brp`.
