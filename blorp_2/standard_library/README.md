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

`bool.brp` defines pure, ordinary `not`, `and` and `or`; select them explicitly
with `bool: not, and, or` for direct calls and UFCS. Both binary arguments are eager;
use an explicit `match` to skip evaluation. The prelude leaves these names available
for user helper declarations and selections of their own ordinary functions.
They import only other library modules and `_base`, never user modules.

For example, `42.add(1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`. IO remains explicit.
Int ordering uses one signed64 `less_than` builtin; the other relations,
`not_equals`, `min` and `max` are ordinary pure functions. Imported `INT_MIN`
and `INT_MAX` are closed scalar literals, with no runtime global storage.
The [imports design](../README.md#local-modules) defines the full rules.

`system.brp` records its accepted upstream revision and source SHA256.
Its explicit `get_current_directory()` import returns `Result[String, String]`:
an owned nonempty absolute UTF-8 path or an owned valid-text error.
Neither branch prints. The native helper uses the target String ABI.

`int.brp` records the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/int.brp`](../../standard_library/src/int.brp). Concrete
`add`, `subtract`, `multiply`, `divide`, `remainder`, `equals` and `to_string` are
active, lifted from trait implementations where needed. The Float adapter
exposes concrete `add`, `subtract`, `multiply`, `divide`, `remainder` and
`to_string` for Float64, plus concrete `copysign`, `equals`, `less_than`,
`is_nan`, `is_finite`, `abs` and `greater_than_or_equal`.
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

Generic `any`, `map` and `filter` accept pure named functions, pure lambdas
(including immutable data captures) and unchanged forwarded callback parameters. `map` permits distinct input/result types;
`filter` keeps input order, and `any` skips later elements after its first True.
These ordinary source helpers use balanced recursion: logarithmic C stack,
with O(n log n) copied List slots for map/filter as a temporary bootstrap cost.
See [the callback plan](../LIST_CALLBACK_PLAN.md); no constant-stack or COW claim
is implied.

List literals are supported. `set_index(values, index, value)` returns
`Option[List[T]]`: `Some(updated)` for a valid index, or `None` for a negative
or out-of-bounds index. `set(values, index, value)` returns `List[T]`:
the updated value for a valid index, or the original value unchanged otherwise.
Replacement arguments are evaluated eagerly in both APIs, including invalid
indices. Updates have value semantics: an update does not change an earlier
alias, and returned managed values remain independently owned. `append` and
`concat` also return owned Lists.

`list: join` imports pure `join(List[String], String) -> String`, also usable
through UFCS. It preserves element order and counted UTF-8/NUL bytes; empty
input returns empty String and separators appear only between elements. The
result owns its content independently of temporary inputs and surviving aliases.
This temporary balanced implementation copies O(n + bytes * log(n + 1)) work
and uses O(log(n + 1)) stack, pending a separately reviewed linear String builder.

### List queries and copies

The combined library also supplies these ordinary pure helpers:

| Function | Contract |
| --- | --- |
| `get_or[T](values, index, default) -> T` | Return the indexed value or the eagerly evaluated default. |
| `is_empty[T](values) -> Bool` | Test whether the length is zero. |
| `last[T](values) -> Option[T]` | Return the last element, or None for an empty List. |
| `take[T](values, count) -> List[T]` | Keep a prefix, clamping count to `0..length`. |
| `drop[T](values, count) -> List[T]` | Remove a prefix with the same clamping. |
| `remove[T](values, index) -> Option[List[T]]` | Remove exactly one valid element; invalid indexes return None. |
| `reverse[T](values) -> List[T]` | Reverse element order. |
| `find[T](values, predicate: pure (T) -> Bool) -> Option[T]` | Return the first match in input order and skip later elements. |
| `all[T](values, predicate: pure (T) -> Bool) -> Bool` | Stop at the first False; empty input returns True. |
| `sort_by[T](values, key: pure (T) -> Int) -> List[T]` | Stable ascending Int-key order; equal keys retain input order. |

Inputs are borrowed; returned managed values retain independent ownership and
older aliases remain valid. Predicate/key callbacks may capture immutable data.
The sort key may run more than once per element; generic `K: Orderable` remains
future work. Take/drop/remove/reverse temporarily copy O(n log n) List slots
with O(log(n + 1)) stack. Find/all visit at most n elements in input order,
with logarithmic stack and short-circuiting. Sort uses a temporary merge
implementation. No COW or constant-stack claim follows from availability.
Integrated correctness, self-compilation and resource acceptance remain separate.

### List membership

`contains_with[A](values: List[A], needle: A, equals: pure (A, A) -> Bool) -> Bool`
uses supplied equality in element/needle order and stops at the first match.
`contains(values: List[Int], needle: Int) -> Bool` uses `int.equals`.
Both functions are pure and borrow their inputs; managed aliases remain valid.
The Int-only adapter is temporary: replace it with general `contains[T: Equatable]`
when the target supports equality traits. The supplied-equality API stays generic.
Indexed `get` and ordinary recursion do O(n) work, with linear C stack at O0 and
ordinary temporary ARC costs. No bounded-stack or zero-allocation claim is made.
Equality traits and optimization of these temporary helpers remain separate.

The List update names match the unchanged host library because the same compiler source
must build against both libraries. The internal `list.set` builtin implements the
no-op-on-invalid update; checked `set_index` is an ordinary function. The desired
later rename to checked `set` and no-op `set_or_keep` must update both libraries
and all callers together; see [the deferred note](../LIBRARY_PARITY.md#deferred-list-update-naming).
The base module provides the ordinary generic Result union with Ok/Err for
pure calculator parsing and evaluation; it has no compiler-specific behavior.

Bool, Option and Result are ordinary fixed unions owned by `_base.brp`; user
modules receive their types and constructors through the prelude. Bool, Option
and Result operations use explicit named imports. `option.brp` provides
`is_some`, `is_none`, eager `get_or`, eager `to_result` and `map`; `result.brp`
provides `is_ok`, `map`, `map_err` and `and_then`. These are ordinary generic pure
functions over the existing base unions. The prelude supplies no operations
from these two modules. Import them by name or through a module alias.

The four callback signatures keep their type parameters independent:

```blorp
pure func map[T, U](self: Option[T], callback: pure (T) -> U) -> Option[U]
pure func map[T, U, E](self: Result[T, E], callback: pure (T) -> U) -> Result[U, E]
pure func map_err[T, E, F](self: Result[T, E], callback: pure (E) -> F) -> Result[T, F]
pure func and_then[T, U, E](self: Result[T, E], callback: pure (T) -> Result[U, E]) -> Result[U, E]
```

Pass a pure named function, a pure lambda with immutable data captures, or
forward a callable parameter. Option.map invokes
it once for Some; Result.map and and_then once for Ok; map_err once for Err.
The other branch preserves its variant and payload without invoking the callback.
Data arguments evaluate eagerly. Inputs are borrowed and returned managed values
remain independently owned, including bypass payloads. Void payloads are supported.
Lambdas/captures and explicit compiler-source operation imports are implemented
in the combined compiler. The [catalog and addition plan](../OPTION_RESULT_PLAN.md)
retains the historical inventory; integrated self-compilation and resource
acceptance remain separate.

The String adapter
exposes strict counted-byte `parse_int`, `parse_float` and `equals` operations.
Their builtin bodies name only the operation; results refer to the
foundation's designated Bool and Option, found by name in `_base.brp`, and
layout follows the unions' declaration order. Each adapter records its upstream
provenance. Traits and FFI remain inactive.

`string.starts_with` is an ordinary pure counted-byte prefix helper.
`string.slice(String, Int, Int) -> Option[String]` uses half-open UTF-8 byte
offsets: invalid bounds or an endpoint inside a scalar return None. A valid
empty or full slice returns Some with an independently owned String, preserving
NUL bytes and source aliases. See the
[String contracts](../README.md#counted-string-operations).

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
[File reading](../README.md#file-reading). The integrated source loader uses
this target interface; whole-compiler self-compilation remains unproved.

`io.print_error(String) -> Void` concretely adapts the host Stringable API.
It borrows its input, writes counted bytes to stderr once, and attempts LF only
following a full transfer; short writes (including EINTR) stop without retry.
The host attempts LF after short writes as well. Neither API reports delivery.

The system adapter publishes impure `write_file(String, String) -> Result[Void, String]`.
Ok carries Void; Err owns a fresh String. See [File writing](../README.md#file-writing)
for counted bytes, one-close error priority and target NUL-path teaching text.

### Logical paths

`path` supplies pure String functions `join`, `dirname` and `normalize`.
Only ASCII `/` separates components; these functions do no filesystem access,
symlink resolution, Unicode normalization or case folding.

`join(base, child)` returns an absolute child unchanged, or the child when the
base is empty. Otherwise it retains or adds `/`, including for an empty child,
without normalizing either input.

`dirname(path)` ignores trailing separators, removes the last component and its
separator run, and preserves interior spelling. Root remains `/`; an empty path
or a basename without a parent yields `.`.

`normalize(path)` removes empty and `.` components and resolves `..` against a
preceding ordinary component. Leading relative parents survive; absolute paths
cannot move above root. Empty relative output becomes `.`, root becomes `/`, and
trailing separators disappear. Other component bytes, including UTF-8 and NUL,
are preserved. OS operations independently reject NUL paths.

The byte scan/materialization is linear, but temporary List append/take and
balanced String joining still copy data; no linear total-cost or COW claim is
made. See the [shell/path boundary](../ROADMAP.md#seven-shell-and-path-functions).
