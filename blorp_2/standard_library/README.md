# Blorp 2 standard library

These modules are compiled by Blorp 2 for input programs. They are separate
from the host library at `standard_library/src/` that builds the pilot compiler.

The directory was renamed from `standard_library_temp` on 2026-10-18. Dated
benchmark reports and retained raw evidence keep the historical path to preserve
measurement provenance; current commands use `blorp_2/standard_library`.

The library root contains two designated foundation modules:

- `_base.brp` owns Int, Float, String, Void, List, Bool, Option and Result. It
  is the only module that may declare builtin types. Any module may import it
  as `_base`.
- `prelude.brp` imports the base types and the operation modules' methods. It
  is the only implicit import: application roots and ordinary user helper
  modules receive its selections, and it cannot be imported explicitly.

Library modules receive nothing implicitly. Each one imports what it uses,
including base types, for example `_base: Int, Bool(True, False)` in `int.brp`.
They import only other library modules and `_base`, never user modules.

For example, `42.add(1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`. IO remains explicit.
Int ordering uses one signed64 `less_than` builtin; the other relations,
`not_equals`, `min` and `max` are ordinary pure functions. Imported `INT_MIN`
and `INT_MAX` are closed scalar literals, with no runtime global storage.
The [imports design](../IMPORTS_AND_PRELUDE_PLAN.md) defines the full rules.

`system.brp` records its accepted upstream revision and source SHA256.
Its explicit `get_current_directory()` import returns `Result[String, String]`:
an owned nonempty absolute UTF-8 path or an owned valid-text error.
Neither branch prints. The native helper uses the target String ABI.

`int.brp` records the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/int.brp`](../../standard_library/src/int.brp). Concrete
`add`, `subtract`, `multiply`, `divide`, `remainder`, `equals` and `to_string` are
active, lifted from trait implementations where needed. The Float adapter
exposes concrete `add`, `subtract`, `multiply`, `divide`, `remainder` and
`to_string` for Float64; `equals` remains pending.
`Int` and `Float` are declared once in `_base.brp`. Other
declarations are enabled only as their features enter the supported subset.
The original modules are maintained in [standard_library/src](../../standard_library/src/).

Pass `blorp_2/standard_library` explicitly as the argument to `--library-root`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io.brp` retains the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/io.brp`](../../standard_library/src/io.brp). Its active
`print(String) -> Void` is concrete and impure, mapped to the closed
`string.print` operation. It borrows the String,
writes every byte and appends LF. Program input arrives explicitly through
`main(args: List[String])`, including the executable name at index 0.
Other IO declarations remain in the original module. `Void` is declared once in `_base.brp`.

The List adapter provides generic `repeat`, `length`, safe `get`, `append`,
`set`, `set_index` and `concat` APIs. List is declared once
in `_base.brp` as a unary builtin. Every supported finite type can be an element,
including records, unions, Void and nested Lists. A successful get returns an
independently owned element inside ordinary Option; invalid indexes return None.
A nonpositive repeat count creates an empty List. Each repeated occurrence
owns its own stored obligation; final root release destroys each initialized
slot once.
List literals are supported. `set_index(values, index, value)` returns
`Option[List[T]]`: `Some(updated)` for a valid index, or `None` for a negative
or out-of-bounds index. `set(values, index, value)` returns `List[T]`:
the updated value for a valid index, or the original value unchanged otherwise.
Replacement arguments are evaluated eagerly in both APIs, including invalid
indices. Updates have value semantics: an update does not change an earlier
alias, and returned managed values remain independently owned. `append` and
`concat` also return owned Lists.

These names match the unchanged host library because the same compiler source
must build against both libraries. The internal `list.set` builtin implements the
no-op-on-invalid update; checked `set_index` is an ordinary function. The desired
later rename to checked `set` and no-op `set_or_keep` must update both libraries
and all callers together; see [the deferred note](../LIBRARY_PARITY.md#deferred-list-update-naming).
The base module provides the ordinary generic Result union with Ok/Err for
pure calculator parsing and evaluation; it has no compiler-specific behavior.

Bool, Option and Result are ordinary fixed unions owned by `_base.brp`; user
modules receive their types and constructors through the prelude. A separate
Bool operation module remains deferred. Option and Result operations use explicit
named imports. `option.brp` provides
`is_some`, `is_none`, eager `get_or` and eager `to_result`; `result.brp` provides
`is_ok`. They are ordinary generic pure functions over the existing base unions;
managed results remain independently owned. The prelude supplies no operations
from these two modules. The [resolved catalog and addition plan](../OPTION_RESULT_PLAN.md)
tracks four remaining helpers that require callable semantics. The String adapter
exposes strict counted-byte `parse_int`, `parse_float` and `equals` operations.
Their builtin bodies name only the operation; results refer to the
foundation's designated Bool and Option, found by name in `_base.brp`, and
layout follows the unions' declaration order. Each adapter records its upstream
provenance. Traits and FFI remain inactive.

The current [calculator](../README.md#calculator-input-and-results) and
[Float contracts](../README.md#float64-calculator) define deliberate conversion and arithmetic
adaptations. The host library provides reference implementations for these adaptations.

A type selection also supplies only that module's local receiver functions:

```blorp
import:
    ./foo: Foo
    ./foo_ops: Foo methods_only
```

`Foo methods_only` requires the exact Foo type independently visible in the
caller. It imports no type or constructors and cannot make bare function calls
available. A module offers only the types it declares, so `int: Int` is
rejected and `int: Int methods_only` uses `int`'s functions on Int; no module
reexports another module's types or methods. The prelude is a compiler input and
cannot be imported explicitly.

The system adapter also publishes impure `read_file(String) -> Result[String, String]`.
Its counted UTF-8 contract and target-only encoding help are documented in
[File reading](../README.md#file-reading); source loader migration remains pending.

`io.print_error(String) -> Void` concretely adapts the host Stringable API.
It borrows its input, writes counted bytes to stderr once, and attempts LF only
following a full transfer; short writes (including EINTR) stop without retry.
The host attempts LF after short writes as well. Neither API reports delivery.

The system adapter publishes impure `write_file(String, String) -> Result[Void, String]`.
Ok carries Void; Err owns a fresh String. See [File writing](../README.md#file-writing)
for counted bytes, one-close error priority and target NUL-path teaching text.

`path: join` imports pure String joining: an absolute child replaces the base; an empty base returns the child.
Otherwise retain/add `/` without normalization; see the [join contract](../ROADMAP.md#seven-shell-and-path-functions).
