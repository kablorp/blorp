# A qualified call reaches a private trait's method

Status: open.

`standard_library/src/fs.brp` keeps `close` in the private trait
`FileClosable` so user code cannot close a handle that a `with` scope will also
close. A qualified call through the module alias still reaches it, and the
checker accepts:

```
import:
	fs as F

func bad(path: String) -> Result[Int, F.IOError]:
	with reader ?= F.open_read(path):
		F.close(reader)
		Ok(0)
```

The generated C calls `blorp_file_close_reader` on the handle for `F.close`
and again for the scope's cleanup; that function frees the handle, so this is a
double free. Importing the method by name is already rejected (`visibility_private_trait_methods_leak` reports
`'secret_method' is private in module ...`); the qualified path skips that
visibility check.

## Where to look

Qualified call resolution in `stage_06_typecheck/infer.brp` (the path that
reports ``Module alias `X` for module `m` has no function `f` ``): it resolves
trait methods of the aliased module without checking the trait's visibility.

## Fixtures (1)

`blorp/test/test_compiler/test_stage_06_typecheck/fixtures/typecheck/should_fail/file_resource_manual_close_qualified_private.brp`

## Acceptance

The program above is rejected at typecheck naming `close` as private to `fs`,
the fixture passes `run_blorp_check_fixtures.py` and is marked
`-- RUN-BLORP-CHECK`.
