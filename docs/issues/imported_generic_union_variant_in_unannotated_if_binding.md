# A variant of an imported generic union built in an unannotated `if` binding fails C emission

Status: open. Found writing the lambda header reader of the discovery stage's
body parser (`parse/tree_body_parser.brp`), which built
`(after_return, return_type) = if ...: (..., Recognized(None)) else: ...` over
the `Recognition[T]` union of `parse/stop_reason.brp`. Related to
[`generic_union_nullary_variant_built_across_modules.md`](generic_union_nullary_variant_built_across_modules.md):
the same cause is likely (a generic union's constructor from another module is
not projected as a callable), but here the variants carry payloads.

Binding the value of an `if` whose branches build a variant of a generic union
that another module defines, without a type annotation on the binding, passes
`bin/blorp check` and then fails in emission:

```
internal C emission failure: missing projected callable `Recognized` (122)
```

The same code builds when the union is declared in the same module, when the
binding is annotated, and when the `if` is the function's result expression.

## Smallest reproduction

`rec.brp`:

```
union Recognition[T]:
	Recognized(T)
	Declined(Int)
```

`main.brp`, in the same directory:

```
import:
	rec: Recognition(Recognized, Declined)

pure func header(n: Int) -> Int:
	annotation = if n > 5:
		Recognized(n)
	else:
		Declined(0)
	match annotation:
		Recognized(_): 1
		Declined(_): 0

func main(args: List[String]) -> Int:
	print("${header(7)}")
	0
```

`bin/blorp run --no-format main.brp` fails with the message above. Each of
these prints `1`:

- declaring `Recognition` in `main.brp` instead of importing it;
- `annotation: Recognition[Int] = if n > 5:`;
- returning the `if` from `header` with `-> Recognition[Int]`.

A tuple binding fails the same way: `(rest, annotation) = if n > 5: (n,
Recognized(n)) else: (n, Declined(0))`.

## Workaround

Annotate the binding, or move the `if` into a function whose result type names
the union. The lambda header reader now matches on the typed results of a
helper instead.
