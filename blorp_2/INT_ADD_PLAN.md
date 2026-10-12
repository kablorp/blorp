# Temporary target library and Int addition

The first target-library fixture imports `add` and returns 42:

```blorp
import:
    int: add

func main() -> Int:
    add(20, 22)
```

Before this increment, the frozen compiler at `7cb72f355` rejects line 2 with
`expected an explicit relative import path`. This is calculator increment 2;
String literals, IO, Float, traits and FFI remain later work.

## Source loading and identity

The CLI accepts `--library-root DIRECTORY` before its three source/output paths.
Omitting the option leaves library imports unavailable. Relative imports resolve
beside their importer; bare paths such as `int` resolve only below the explicit
library root. There is no local-file or host-library fallback. Parsing publishes
`RelativeImport(parent_count)` or `LibraryImport` plus interned components;
loading replaces those requests with existing `ModuleId` edges. Library files
use the same loading, parsing, namespace and checking path as other modules.

`standard_library_temp/int.brp` derives from `standard_library/src/int.brp`.
Unsupported declarations stay commented out. Its concrete `add` is lifted out
of `implements Addable`. The input prelude continues to own `Int` and `String`;
the library does not duplicate their declarations.

## Builtin declarations

```blorp
pure func add(a: Int, b: Int) -> Int:
    builtin("int.add")
```

This is an explicit declaration of a closed compiler-known operation, available
in any module. A directory does not confer semantic trust. Arbitrary C symbols,
foreign declarations and user-defined operation labels remain unavailable.
Parsing translates the label once to a typed operation and publishes a distinct
builtin body. Builtin bodies have no binding prefix, generic parameters or tail
annotation. Checking validates exact purity, ordered parameter types and result
against the single runtime-contract authority.

In module bodies, the quoted-label form selects the intrinsic declaration;
`builtin()` and `builtin(value)` remain ordinary calls to a declared function.
Prelude bodies retain their existing requirement for a builtin declaration.

The declaration retains its ordinary module-owned `FunctionId` and accepted
signature. Checking elaborates the body into the existing runtime-call
expression, reading the parameter identities established by function scope.
Specialization, lowering, ownership and verification consume the usual call
facts. No builtin-specific checked body, namespace registry or new pass is
needed. Runtime contracts now describe a parameter list rather than one
parameter, also covering the existing unary operations.

This follows the separation between typed primitive declarations and their
backend implementation used by [OCaml primitive declarations](https://ocaml.org/manual/4.04/intfc.html).
The application to Blorp's closed operations is our design choice; OCaml's
general foreign interface is outside this pilot's scope.

## Arithmetic and validation

`Int.add` wraps modulo 2^64, consistent with Blorp's existing Int contract and
[Rust's explicit wrapping addition](https://doc.rust-lang.org/std/primitive.i64.html#method.wrapping_add).
The C helper adds unsigned operands and reconstructs the signed result using
only representable signed conversions and arithmetic. It must pass UBSan at
both signed limits. Emit the helper only when needed so existing programs retain
their generated C.

Add granular parser, contract, checker, specialization and emission tests.
Loader tests cover explicit roots, missing roots/files, relative imports inside
the library, same-path deduplication and the absence of local/host fallback.
Native fixtures use the normal main with ASan/UBSan, direct calls and UFCS.
Boundary fixtures also observe signed decimal length through existing
`to_string` and `length`, rather than relying only on truncated process exit
status. This distinguishes the signed-limit wrap directions but does not prove
every output digit; an exact full-width native oracle awaits String comparison
or output in a later increment.
Deliberately break addition and require the relevant regression to fail.

Frozen baseline binaries and raw evidence live under ignored
`build/int-add/`. Compare baseline/candidate allocations and retired instructions
on identical existing inputs, with ceilings of +10% for each aggregate proxy
metric. Self-compilation remains unsupported. Aim for at most 700 added
production lines; report production and test changes separately. Investigate
and rescope repeatable excesses rather than adding speculative indexes or
special cases. Set new fixture cost ceilings after retaining observed costs.

Run focused tests first, then the unit/runtime/grammar suites under sanitizers
and strict leak checking, followed by the end-to-end suite. Compiler-expert
implementation and independent code/test review are required.
