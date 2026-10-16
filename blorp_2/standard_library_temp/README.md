# Temporary input library

These modules are compiled by Blorp 2 for input programs. They are separate
from the host library that builds the pilot compiler.

The library root contains two designated foundation modules:

- `_base.brp` owns Int, Float, String, Void, List, Bool, Option and Result. It
  is the only module that may declare builtin types. Any module may import it
  as `_base`.
- `prelude.brp` imports the base types and the operation modules' methods. It
  is the only implicit import: application roots and ordinary user helper
  modules receive its selections, and it cannot be imported explicitly.

Library modules receive nothing implicitly. Each one imports what it uses,
including base types, for example `_base: Int, Bool` in `int.brp`.
They import only other library modules and `_base`, never user modules.

For example, `42.add(1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`. IO remains explicit.
The [imports design](../IMPORTS_AND_PRELUDE_PLAN.md) defines the full rules.

`int.brp` records the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/int.brp`](../../standard_library/src/int.brp). Concrete
`add`, `subtract`, `multiply`, `divide`, `remainder`, `equals` and `to_string` are
active, lifted from trait implementations where needed. The Float adapter
exposes those same concrete names for Float64.
`Int` and `Float` are declared once in `_base.brp`. Other
declarations are enabled only as their features enter the supported subset.
The original modules are maintained in [standard_library/src](../../standard_library/src/).

Pass `blorp_2/standard_library_temp` explicitly as the argument to `--library-root`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io.brp` retains the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/io.brp`](../../standard_library/src/io.brp). Its active
`print(String) -> Void` is concrete and impure, mapped to the closed
`string.print` operation. It borrows the String,
writes every byte and appends LF. Program input arrives explicitly through
`main(args: List[String])`, including the executable name at index 0.
Other IO declarations remain in the original module. `Void` is declared once in `_base.brp`.

The List adapter follows `standard_library/src/list.brp`'s generic `repeat`,
`length` and safe `get` APIs. List is declared once in `_base.brp` as a unary
builtin. Every supported finite type can be an element, including records,
unions, Void and nested Lists. A successful get returns an independently owned
element inside ordinary Option; invalid indexes return None. A nonpositive
repeat count creates an empty List. Each repeated occurrence owns its own
stored obligation; final root release destroys each initialized slot once.
No List literals, append or indexed mutation are enabled yet.
The base module provides the ordinary generic Result union with Ok/Err for
pure calculator parsing and evaluation; it has no compiler-specific behavior.

Bool, Option and Result are ordinary fixed unions owned by `_base.brp`; user
modules receive their types and constructors through the prelude. Separate Bool,
Option and Result operation modules are deferred until operations need them. The String adapter
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
