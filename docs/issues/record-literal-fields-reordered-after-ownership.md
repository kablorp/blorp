# Record literal fields are reordered after ownership, reading a consumed value

Status: open. Ledger: CF-011 in `docs/DIAGNOSTIC_GAPS.md`. A fix is in
progress on branch `fix/record-literal-written-order`.

A record literal whose fields are written in a different order from the
declaration is evaluated in declaration order, but Perceus decided ownership
for the written order. When an earlier written field borrows a value that a
later written field consumes, the consuming field now runs first and the
borrowing field reads freed memory.

## Smallest reproduction

`order3.brp`:

```
record Holder {
    names: List[String],
    count: Int
}


pure func build(seed: String) -> Holder:
    names: List[String] = [seed, seed + "!"]
    {count = names.length(), names = names.append("x")}


func main(args: List[String]):
    holder: Holder = build("abc${args.length()}")
    print("${holder.count} ${holder.names.length()}")
```

```sh
bin/blorp run --no-format order3.brp            # prints "0 3", expected "2 3"
bin/blorp run --no-format --sanitize order3.brp # heap-use-after-free in build
```

A field with side effects shows the same reordering without a memory error:
`{second = noisy("second", 2), first = noisy("first", 1)}` prints `first`
before `second`.

## Cause

Lowering keeps the written order (`--dump-core-after=perceus` shows the
fields as `count, names`). Perceus moves `names` into the `names` field,
because that is its last use in written order, and leaves the earlier
`names.length()` as a borrow. After Perceus, `prepare_record_expr` and
`declaration_ordered_record_fields` in
`blorp/src/compiler/stage_09_core/prepare.brp` reorder the field list into
declaration order to build `RecordConstructExpr`, and the emitter evaluates
the fields in list order. The consuming `append` runs first, may reallocate
the list, and the `length` read follows it. One list order carries two facts,
evaluation order and storage order, and a pass after ownership changed one of
them.

`docs/issues/record-update-same-field-read-copies.md` records that update
replacements also run in declaration order. Record-update lowering stages
replacement values before the transfer, and the matching update
`{ holder | count = holder.names.length(), names = holder.names.append("x") }`
prints the expected values; pin it alongside the literal.

## Change that closes it

The rule is decided: fields are evaluated in written order and stored by
declared position, as in Rust. Keep that order fixed after ownership
analysis. Either lowering binds every field to a temporary in written order
whenever the written order differs from declaration order, so the record is
built from variables, or each field value carries its storage position and
the emitter evaluates in list order while storing by position. The second is
the construction form planned in
[`PRODUCT_UNIFICATION.md`](../PRODUCT_UNIFICATION.md#2-operations). State the
rule in the Guide.

Tests: the reproduction above as a runtime value test and an ASan case, the
side-effect ordering case, and the update shape above.
