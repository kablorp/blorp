# A payload-less variant of an imported generic union emits an undeclared C identifier

Status: open. Found building the trait and implementation owner readers of the
discovery stage (`parse/method_read.brp` works around it).

Building a payload-less variant of a generic union that another module
defines emits the variant's bare name into the C, so the C compiler fails with
`use of undeclared identifier`. The same union built in its own module, a
union with payloads only, and a non-generic union with a payload-less variant
are all fine.

## Smallest reproduction

`reads.brp`:

```
union Read[M]:
	Got(M)
	Missing
```

`main.brp`, in the same directory:

```
import:
	reads: Read(Got, Missing)

pure func reader(n: Int) -> Read[Int]:
	if n == 0:
		Missing
	else:
		Got(n)

func main(args: List[String]) -> Int:
	match reader(0):
		Got(_): print("got")
		Missing: print("missing")
	0
```

`bin/blorp run --no-format main.brp` fails:

```
error: use of undeclared identifier 'Missing'
  return ((brp_v_S == 0) ? Missing : brp_c_pO(brp_v_S));
```

Returned inside a tuple (`(n, Missing)` with `-> (Int, Read[Int])`) it fails the
same way, as `(void*)Missing`. Removing `[M]` from the union (with a concrete
payload), or defining `reader` in `reads.brp`, makes it build and print `missing`.

## Where it appeared

`TraitMethodRead[M]` had payload-less variants `RejectedTraitMethod` and
`UnsupportedTraitMethod`; `tree_owner_completion.brp` built them from another
module and passed the readers to the generic `parse_trait_owner[M]`. The
discovery stage now returns `Result[Option[M], S]` instead.

## Likely cause

The constructor of a payload-less variant is lowered to a value of the union's
instantiated type only when the union's own module emits it. An imported
generic union's variant has no instantiation at the use site, so the emitter
falls back to the variant's source name. Start in the emitter's handling of
variant constructors of generic unions, and add the reproduction above as a
`should_pass` fixture when it is fixed.
