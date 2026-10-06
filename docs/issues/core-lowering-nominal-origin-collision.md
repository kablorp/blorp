# A local `Option` and the prelude `Option` lower to the same Core type

Status: open. Found while scoping declaration/use identity for the fixed-record
layout work (item 1 of
[`FIXED_LAYOUT_ROADMAP.md`](../FIXED_LAYOUT_ROADMAP.md#recover-ownership-prerequisites-in-bounded-slices)).

A module that declares its own `union Option[T]` type-checks and lowers, but the
prelude `Option` (embedded from `option`) is still in the program. After
lowering, a use of either is the same Core type reference:
`{"kind":"named","name":"Option","args":[...]}`. Core carries two `Option`
union declarations, one from `<embedded:option>` and one from the user's file,
and nothing on a use says which one it names. Compilation then fails after
specialization:

```
selected direct call survived Core call resolution
help: Core call resolution must classify selected function identity `142` before specialization
```

## Smallest reproduction

`local_option.brp`:

```
union Option[T]:
	Local(T)

pure func local_value(value: Option[Int]) -> Option[Int]:
	value

func main(args: List[String]) -> Int:
	1
```

```sh
bin/blorp compile --no-format --dump-core-after=lower \
  --dump-core-file=lower.core --stop-after=lower local_option.brp
sed -n '3p' lower.core | jq -c '.decls[]
  | select((.kind == "function" and .name == "local_value")
           or (.kind == "union" and .name == "Option"))
  | {kind,name,abi_type,source:.loc.file,params:[.params[]?.type],return_type}'
bin/blorp compile --no-format -o local_option.c local_option.brp
```

Observed on `6606c0ff1`, and rechecked on a freshly built `bin/blorp` at
`de9ca3042`. Lowering exits 0 and prints these rows:

```
{"kind":"union","name":"Option","abi_type":"option","source":"<embedded:option>",...}
{"kind":"union","name":"Option","abi_type":null,"source":"local_option.brp",...}
{"kind":"function","name":"local_value","params":[{"kind":"named","name":"Option","args":[{"kind":"named","name":"Int","args":[]}]}],"return_type":{"kind":"named","name":"Option","args":[...]}}
```

The full compile exits 1 with the diagnostic above and writes no C. Renaming
the local union to `LocalOption` makes the program compile. Adding a use of the
prelude type next to the local one (`import: option as StdOption`, then a
function over `StdOption.Option[Int]`) fails the same way, with a different
function identity. These runs show that the spelling triggers the failure, not
why call resolution rejects it.

## Why it matters

A name and its arguments are the only identity a type use carries from
`SemanticNamedType` through lowering to Core, so Core cannot tell a use of the
prelude `Option` from a use of a same-spelled local declaration. The
standard library keeps bare ABI names and local declarations stay bare in their
own module, so nothing disambiguates them later. Any layout, ownership or ABI
decision keyed on a declaration's name is therefore unsound when two
declarations share a spelling. A fixed layout must not be admitted until each
type use names its declaration. That is the declaration/use identity work in
roadmap item 1, which this issue is a failing case for.

Nominal origin has to be carried from semantic uses, through the lowering
type-kind query, to flatten's declaration/use rewrite. That fanout needs its own
design and gate plan before code.

## Workaround

Give the local type a name that differs from every standard library type, for
example `LocalOption`.

## Closes when

The repro compiles, and the two `Option` uses are distinct in Core.
