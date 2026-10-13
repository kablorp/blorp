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
including base types, for example `_base: Int, Bool(True, False)` in `int.brp`.
They import only other library modules and `_base`, never user modules.

For example, `42.add(1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`. IO remains explicit.
The [imports design](../IMPORTS_AND_PRELUDE_PLAN.md) defines the full rules.

`int.brp` records the revision and SHA256 of its
[upstream reference](../reference/standard_library/int.brp). Concrete `add`, `subtract`, `multiply`,
`divide`, `remainder`, `equals` and `to_string` are active, lifted from trait implementations
where needed. The Float adapter exposes those same concrete names for Float64.
`Int` and `Float` are declared once in `_base.brp`. Other
declarations are enabled only as their features enter the supported subset.
Byte-for-byte upstream references live outside compilation inputs under
[reference/standard_library](../reference/standard_library/README.md).

Pass `blorp_2/standard_library_temp` explicitly as the argument to `--library-root`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io.brp` retains the upstream `standard_library/src/io.brp` revision and SHA256
beside a link to its reference copy. Its active `print(String) -> Void` is concrete and
impure, mapped to the closed `string.print` operation. It borrows the String,
writes every byte and appends LF. Program input arrives explicitly through
`main(args: List[String])`, including the executable name at index 0.
Other IO declarations remain in the reference copy. `Void` is declared once in `_base.brp`.

The small List adapter follows `standard_library/src/list.brp`'s `length` and
safe `get` APIs, with concrete List[String] signatures for this increment.
List is declared once in `_base.brp` as a unary builtin. A successful get
returns an owned String inside ordinary Option, independently of the list's
lifetime; invalid indexes return None. No list literals, append or mutation are
enabled yet. The base module provides the ordinary generic Result union with Ok/Err for
pure calculator parsing and evaluation; it has no compiler-specific behavior.

Bool, Option and Result are ordinary fixed unions owned by `_base.brp`; user
modules receive their types and constructors through the prelude. Separate Bool,
Option and Result operation modules are deferred until operations need them. The String adapter
exposes strict counted-byte `parse_int`, `parse_float` and `equals` operations.
Their builtin bodies explicitly bind the ordinary result constructors; names
and declaration order have no hidden runtime meaning. Copied upstream source
is reference material outside this input library, with provenance beside each
adapter. Traits and FFI remain inactive.

The current [calculator](../README.md#calculator-input-and-results) and
[Float contracts](../README.md#float64-calculator) define deliberate conversion and arithmetic
adaptations. The copied host implementation is a reference, not an implicit
source of semantics or runtime dependencies.

A type selection also supplies only that module's local receiver functions:

```blorp
import:
    ./foo: Foo
    ./foo_ops: Foo methods_only
```

`Foo methods_only` requires the exact Foo type independently visible in the
caller. It imports no type or constructors and cannot make bare function calls
available. Type forwarding follows the original declaration; it does not
forward another module's imported methods. The prelude is a compiler input and
cannot be imported explicitly.
