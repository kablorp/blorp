# Blorp standard library

These modules are compiled by Blorp for input programs. They are separate
from the legacy library, preserved at
[`standard_library/src/`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/). All active Blorp tests
use this target library. The
pinned Blorp2 compiler uses this target library when compiling compiler source.

The directory was renamed from `standard_library_temp` on 2026-10-18. Dated
benchmark reports and retained raw evidence keep the historical path to preserve
measurement provenance; current commands use `blorp/standard_library`.

The library root contains two designated foundation modules:

- `_base.brp` owns Int, Float, String, Void, List, Bool, Option, Result, the
  `Equatable`, `Orderable`, `Hashable` and `Stringable` traits and the arithmetic traits
  `Addable`, `Subtractable`, `Multipliable`, `Divisible`, `Modulable` and
  `Negatable`, plus the checked-arithmetic error `MathError`. It is the only
  module that may declare builtin types. Any module may import it as `_base`.
- `prelude.brp` imports the base types, the operation modules' methods and
  `io/console`'s `print` and `print_error`. It
  is the only implicit import: application roots and ordinary user helper
  modules receive its selections, and it cannot be imported explicitly.

A library module may live in a folder, as `io/environment.brp` imported
as `io/environment`. A module file may not sit beside a folder of the same name; the
loader rejects an import that passes through such a name. On disk any folder
counts, but the embedded library records only `.brp` files, so a folder with none
(a README alone) does not count there.

Library modules receive nothing implicitly. Each one imports what it uses,
including base types, for example `_base: Int, Bool(True, False)` in `int.brp`.
`_base.brp` owns canonical Equatable beside the other core traits. The prelude
selects that trait; operation modules provide written
Int/Float/String/List implementations. Equality imports name this one family,
so aliases and contextual callable references dispatch by the actual receiver.
`Orderable` requires `less_than` and defaults `greater_than`, `less_than_or_equal`
and `greater_than_or_equal` from it; the defaults assume a total order. A library
module may implement a trait declared in `_base`, or the canonical Equatable, for
a type declared in `_base`: `int.brp`
and `float.brp` implement Equatable, Orderable and the six arithmetic traits,
`string.brp` implements Equatable and Addable, and `list.brp` implements Equatable.
`Stringable` has one member, `to_string(value: Self) -> String`, which every
interpolation hole that is not already a String calls. Int, Float, String
(as the identity) and Bool (`True` and `False`) implement it.
Each arithmetic trait has one member: `add`, `subtract`, `multiply`, `divide` and
`remainder` take `(left: Self, right: Self)`, `negate` takes `(value: Self)`, and
each returns `Self`. The prelude's selection makes them the canonical traits of
`+`, `-`, `*`, `/`, `%` and prefix `-`, so user code writes `a + b` or
`a.add(b)` alike. Library implementation code uses operators for ordinary
arithmetic and ordering; trait definitions and direct member delegation call
members through UFCS, as in `left.equals(right)`.

`bool.brp` defines pure, ordinary `not`, `and` and `or`. Select them by name,
as in `bool: not, and, or`, for direct calls, or use `bool: Bool methods` for
UFCS (`done.not()`, `left.and(right)`), as the compiler source does. Both
binary arguments are eager; use an explicit `match` to skip evaluation. The prelude leaves these names available
for user helper declarations and selections of their own ordinary functions.
They import only other library modules and `_base`, never user modules.

For example, `(42 + 1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`; `add` selected from both `int`
and `string` names the one Addable family. IO remains explicit.
Int implements `Orderable` with one signed64 `less_than` builtin and the trait's
defaults. `not_equals` uses the canonical
trait default. Imported `INT_MIN`
and `INT_MAX` are closed scalar literals, with no runtime global storage.
The [imports design](../README.md#modules-imports-and-the-prelude) defines the full rules.

`io/environment.brp`'s explicit `get_current_directory()` import returns
`Result[Path, CurrentDirectoryError]`: a `Path`, or `NotFound`, `PermissionDenied`,
`InvalidUtf8`, `Unreachable` or `OtherOs(Int)`. The `system.current_directory`
native returns the path as a String or an Int code of the file protocol, which a
decoder in the module (public for its test, not API) turns into the union. Neither branch prints.

`int.brp` adapts the legacy
[`standard_library/src/int.brp`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/int.brp). Its
arithmetic implementations have builtin bodies except `negate`, which is
`subtract(0, value)` and so wraps `INT_MIN` to itself; `to_string` implements
`Stringable` with a builtin body.
Its six `_checked` functions are ordinary pure functions returning
`Result[Int, MathError]`. `add_checked` and `subtract_checked` compare the
operands with `INT_MIN` and `INT_MAX` without wrapping; `multiply_checked`
detects a wrapped product by dividing it back; `divide_checked`,
`remainder_checked` and `negate_checked` test for 0, -1 and `INT_MIN`. The
prelude selects neither MathError nor its cases, so `Overflow` and
`DivisionByZero` stay free for user declarations; naming the type or a case
requires `_base: MathError(DivisionByZero, Overflow)`.
The Float adapter implements the same six traits for Float64, with `negate` as
`multiply(value, -1.0)` so that the sign of zero flips, `Stringable` with a
builtin `to_string`, plus concrete `copysign`, `equals`, `is_nan`, `is_finite`
and `abs`. `is_nan`
uses ordinary self-equality, and `is_finite` compares
ordinary self-subtraction with zero; neither requires a builtin label.
Float implements `Orderable`: every comparison with NaN is false, so
it writes its own `less_than_or_equal` and `greater_than_or_equal`.
`Hashable` is an ordinary foundation trait with the pure method
`hash(value: Self) -> Int`. The prelude supplies the trait name and Int's method
route; direct calls use `int: hash`. Int's written implementation returns its
value unchanged, including negative values and `INT_MIN`. Hashes may be any
signed Int. For values compared by equality, equal values must have equal hashes;
distinct values may collide. Hashable requires Equatable, written or
automatic, so a hashed type also has `==`. A hash is never derived.
String writes its hash in `string.brp` (a fold of its bytes from a fixed basis,
unseeded) and Bool in `bool.brp` (`False` 0, `True` 1). The compiler's
`Dict[K, V]` (`K: Hashable`) uses this method
for home slots and still compares keys by equality when probing collisions.

`Int` and `Float` are declared once in `_base.brp`. Other
declarations are enabled only as their features enter the supported subset.
The original modules are preserved in the legacy
[standard_library/src](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/).

Pass `blorp/standard_library` explicitly as the argument to `blorp compile --library-root`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io/console.brp` adapts the legacy
[`standard_library/src/io.brp`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/io.brp). The prelude
supplies `print` and `print_error`. `print(String) -> Void` is concrete and
impure, mapped to the closed `string.print` operation. It borrows the String,
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
These ordinary source helpers are loops. `map` and `filter` append to a local
accumulator that each append consumes, so they visit every element once, grow
the result in place and use constant C stack.

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
A loop appends each separator and element to a dying String accumulator, so the
work is linear in the output bytes and the C stack is constant.

### Dict

`dict.brp` declares the opaque `Dict[K: Hashable, V]`, an insertion-ordered map
over parallel Lists and an open-addressing index. Int, String, Bool and Lists of
keys are keys; a record or opaque key writes its own `Hashable` and
`Equatable` first, except that a record or union whose fields are all Equatable
already has `==` and writes only `Hashable`. A key with several parts hashes them
with `combine_hash(seed, value) = (seed + value) * 1099511628211`, wrapping:
start from 0 and combine every part in order, the first included, because
combining two parts directly is symmetric. A List of Hashable elements is
Hashable, combining its length and then each element in order, and a List of keys is a
key; both live in `dict.brp` beside `combine_hash`, since `list.brp` is imported
by `dict.brp`. The prelude imports `dict: Dict`, so
the type and its receiver methods are implicit; `empty` and `dict` are
reached as `import: dict as dict_ops`. All functions are pure.

Literals need no import. `{}` is `empty()` and takes its key and value types from
the expected type; without one it is rejected with "an empty Dict needs its
type", so write `name: Dict[K, V] = {}`. `{k1 => v1, k2 => v2}`, with an optional
trailing comma, is `dict(2)` then `set(k1, v1)` and `set(k2, v2)`, left
to right and each key before its value, so a repeated key keeps its first
position and its last value. Checking calls these functions of this module by
identity, so no other `set` can stand in, and a literal costs what those calls
cost.

| Function | Contract |
| --- | --- |
| `empty[K: Hashable, V]() -> Dict[K, V]` | No entries. |
| `dict[K: Hashable, V](initial_capacity) -> Dict[K, V]` | Room for `initial_capacity` entries before the index grows; at most 1,048,576 are reserved, a larger or negative count is only a hint. |
| `get(self, key) -> Option[V]`, `get_or(self, key, default) -> V`, `contains(self, key) -> Bool` | O(1) average lookups; a missing key is `None` or the eagerly evaluated default. |
| `set(self, key, value) -> Dict[K, V]` | Insert, or replace the value and keep the key's position. O(1) amortized. |
| `remove(self, key) -> Dict[K, V]` | Without the key, order of the rest kept; unchanged when absent. O(1) amortized. |
| `keys(self) -> List[K]`, `values(self) -> List[V]`, `entries(self) -> List[(K, V)]` | Live entries in first-insertion order; a key removed and set again goes last. |
| `length(self) -> Int`, `is_empty(self) -> Bool` | The live entry count, in O(1). |

`Equatable` for `Dict[K: Hashable, V: Equatable]` compares lengths, then looks up
each key of one Dict in the other, whatever the order. A Dict is not
`Hashable`, and Float is not a key. An update to a uniquely owned
Dict appends to or sets its field Lists in place; a shared Dict copies on write.
Home slots multiply the hash by an odd constant first, so sequential Int hashes
do not form one long run; slot counts are 2^k - 1, and a rebuild at half load
compacts removed entries.

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
| `slice[T](values, start, end) -> List[T]` | Keep `start` up to, not including, `end`. Both bounds clamp to `0..length` and an `end` before `start` gives an empty List, so it never fails. |
| `starts_with[Element: Equatable](values, prefix) -> Bool` | Whether the leading elements equal `prefix`; every List starts with `[]`. |
| `index_of[Element: Equatable](values, needle) -> Option[Int]` | The index of the first element equal to `needle`, or None. |
| `reverse[T](values) -> List[T]` | Reverse element order. |
| `find[T](values, predicate: pure (T) -> Bool) -> Option[T]` | Return the first match in input order and skip later elements. |
| `all[T](values, predicate: pure (T) -> Bool) -> Bool` | Stop at the first False; empty input returns True. |
| `sort_by[T, Key: Orderable](values, key: pure (T) -> Key) -> List[T]` | Stable ascending key order; equal keys retain input order. A key order that is not total, such as Float NaN, still yields a permutation, in an unspecified order. |

Inputs are borrowed; returned managed values retain independent ownership and
older aliases remain valid. Predicate/key callbacks may capture immutable data.
The sort key may run more than once per element. Take/drop/remove/reverse copy
each kept element once into an accumulator that grows in place; remove joins its
two copies with one `concat`. Find/all visit at most n elements in input order
with constant stack and short-circuiting. Sort is a bottom-up merge sort over
two buffers: each of its log n passes merges adjacent runs from one buffer into
the other with `set`, so a sort does O(n log n) key comparisons and copies with
constant stack, and allocates at most two Lists, each buffer's first copy of a
shared input.
Integrated correctness, self-compilation and resource acceptance remain separate.

A List of `Orderable` elements is `Orderable`: lexicographic, the first differing
position decides, and a prefix sorts before the longer List. `[1, 2] < [1, 3]`,
`[1] < [1, 2]`.

### Largest and smallest

`max[T: Orderable](first, second) -> T` and `min[T: Orderable](first, second) -> T`
are declared once, in `order.brp`, and the prelude selects them. `_base` cannot
hold them, because it declares no functions. Both `max(a, b)` and `a.max(b)`
work for Int, Float, a List of Orderable and any user type that implements
`Orderable`. When neither argument is less, both return `first`. String has no
`Orderable` yet, so `max` and `min` do not accept Strings.

### List membership

`contains[Element: Equatable](values: List[Element], needle: Element) -> Bool`
compares each element with the needle using `==`, in element/needle order, and
stops at the first match. It uses the selected equality implementation. String,
named record and nested List elements work when they satisfy that bound;
authored equality takes precedence. A search by other criteria uses
`any(values, predicate)`. The function is pure and borrows its inputs; managed
aliases remain valid. List equality itself uses a single length/get index walk,
without copying suffixes. Float NaN remains unequal to itself.
It iterates the List once with a `for` loop, doing O(n) work with constant C
stack and ordinary temporary ARC costs. No zero-allocation claim is made.
Further helper optimization is deferred; these equality contracts are supported.

The List update names matched the legacy library, so one compiler source could be
built against both; that constraint is gone. The internal `list.set` builtin implements the
no-op-on-invalid update; checked `set_index` is an ordinary function. The desired
later rename to checked `set` and no-op `set_or_keep` updates this library
and all callers together.
The base module provides the ordinary generic Result union with Ok/Err for
pure calculator parsing and evaluation; it has no compiler-specific behavior.

Bool is a fixed union and Option and Result are ordinary unions, all owned by
`_base.brp`; user modules receive their types and constructors through the
prelude. Bool, Option
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
in the combined compiler. Integrated self-compilation and resource acceptance
remain separate.

The String adapter
exposes strict counted-byte `parse_int`, `parse_float` and `equals` operations.
Their builtin bodies name only the operation; results refer to the
foundation's designated Bool and Option, found by name in `_base.brp`, and
layout follows the unions' declaration order. FFI remains inactive.

`string.starts_with` is an ordinary pure counted-byte prefix helper.
`string.lines(text) -> List[String]` splits at each LF and drops it with a CR just
before it, exactly as `fold_lines` does: a last line without LF is kept, a lone CR
stays in its line, and empty text has no lines. It reads the text once and
appends to a growing List in place.
`string.slice(String, Int, Int) -> Option[String]` uses half-open UTF-8 byte
offsets: invalid bounds or an endpoint inside a scalar return None. A valid
empty or full slice returns Some with an independently owned String, preserving
NUL bytes and source aliases. See the
[String contracts](../README.md#string-operations).

The current [calculator](../README.md#command-line-input) and
[Float contracts](../README.md#numbers-and-operators) define deliberate conversion and arithmetic
adaptations. The legacy library, preserved at
[`standard_library/src/`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/), has reference implementations for these adaptations.

A type selection also supplies only that module's local receiver functions:

```blorp
import:
    ./foo: Foo
    ./foo_ops: Foo methods
```

`Foo methods` requires the exact Foo type independently visible in the
caller. It imports no type or constructors and cannot make bare function calls
available. A module offers only the types it declares, so `int: Int` is
rejected and `int: Int methods` uses `int`'s functions on Int; no module
reexports another module's types or methods. The prelude is a compiler input and
cannot be imported explicitly.

`io/console.print_error(String) -> Void` concretely adapts the host Stringable API.
It borrows its input, writes counted bytes to stderr once, and attempts LF only
following a full transfer; short writes (including EINTR) stop without retry.
The host attempts LF after short writes as well. Neither API reports delivery.

There is no shared file error type. Each `io/fs/` module owns the error union of
its operations, and the error carries no path: the caller knows the path and
words it as `"${path}: ${error}"`. `io/_codes.brp` holds the native error codes
that each module's decoder names. `io/_codes` is internal by convention only:
Blorp has neither re-exports nor module-private imports, so its constants are
public by necessity, but they are not part of the library's API. Programs should
not import it, and it may change without notice. (`_base`, the foundation
module, is the other underscore module, and any module may import it.) The
decoders in the `io/fs/`, `io/environment` and `io/process` modules are public
for the same reason: tests bind them to literal codes, and they are not API.

### JSON

Explicitly import `json` for a pure JSON codec:

```blorp
import:
    json: Json(Null, Boolean, Number, Text, Array, Object), parse, render, integer

pure func response() -> String:
    render(Array([Number(integer(42)), Text("ready"), Null]))
```

This returns `[42,"ready",null]`. `parse(text) -> Result[Json, ParseError]`
accepts one complete JSON value with optional JSON whitespace. `Json` carries
`Null`, `Boolean(Bool)`, `Number(JsonNumber)`, `Text(String)`,
`Array(List[Json])` or `Object(Dict[String, Json])`. An object's `get` returns
`None` for an absent name and `Some(Null)` for explicit null.

`number(text) -> Result[JsonNumber, ParseError]` validates an entire number
lexeme without whitespace. `number_text(number) -> String` returns its exact
spelling; `integer(Int) -> JsonNumber` constructs one infallibly. The opaque
number retains every decimal digit, exponent spelling and negative zero;
parsing and rendering never convert it to Float. Thus `9007199254740993` and
`1E400` survive unchanged.

`render(value) -> String` produces compact JSON, preserving object insertion
order and exact number spelling. It escapes quotation marks, backslashes and
controls, leaving other Unicode literal. Parsing decodes every JSON escape,
including UTF-16 surrogate pairs. Unpaired surrogate escapes reject: this
codec accepts Unicode scalar strings, a character-content restriction under
[RFC 8259 section 9](https://www.rfc-editor.org/rfc/rfc8259#section-9).
Duplicate decoded object names also reject, including `"a"` and `"\u0061"`
in the same object; nested objects have independent names. There are no
comments, trailing commas, non-JSON whitespace or byte order mark extensions.

`as_int(number) -> Option[Int]` is `Some` only when the whole lexeme is an
optional minus and decimal digits that fit Int64; `-0` is `Some(0)`. A
fraction or exponent makes it `None` even when the value is whole (`1.0`,
`1e3`), as does a value outside Int64 (`9223372036854775808`). It never
rounds, and `number_text` still returns the exact spelling.

`ParseError` has `offset: Int`, a zero-based UTF-8 byte offset, and
`kind: ParseErrorKind`. Match on the kind; `error.to_string()` and
`"${error}"` give its fixed wording, such as `expected a JSON value`, without the
offset. The kinds are `ExpectedValue`, `ExpectedNull`, `ExpectedTrue`,
`ExpectedFalse`, `ExpectedNumberDigit`, `ExpectedFractionDigit`,
`ExpectedExponentDigit`, `TrailingNumberData` (from `number` only),
`ExpectedArrayDelimiter`, `ExpectedObjectName`, `ExpectedColon`,
`ExpectedObjectDelimiter`, `DuplicateName`, `UnclosedString`,
`UnescapedControl`, `ExpectedEscape`, `ExpectedHexDigits`,
`UnpairedSurrogate`, `TrailingData` and `TooDeep`.
End-of-input errors point at byte length; a duplicate name points at its
second opening quote. An invalid present escape points at its backslash,
and a bad hex digit points at that digit. A missing escape byte at end of
input points at byte length. For example, `["é",x]` fails at byte 6 with
kind `ExpectedValue`.

Parsing rejects containers nested deeper than `MAX_NESTING_DEPTH` (512)
with `TooDeep`, at the bracket that opens too deep: `[` repeated 513 times
fails at byte 512, while 512 levels parse. This bounds the native stack
for untrusted input; real documents rarely pass a few dozen levels.
`render` does not bound depth: it uses one native frame per level of the
tree it is given, which the caller built, so a tree deeper than a few
thousand levels can exhaust the stack. Every tree from `parse` is safe. The
comment on `MAX_NESTING_DEPTH` in `json.brp` records how the limit was chosen.

Parsing rendered values reconstructs their scalar contents, container members
and exact numeric lexemes. Source whitespace and escape spelling normalize.
There is no library size or digit-count limit. Memory follows the input and
result, and parsing and rendering cost time linear in them.

### The file modules

The filesystem library is one module per operation under `io/fs/`; import each
explicitly. Every operation takes a `Path` and returns a union that holds only
the failures that operation can cause (races count: another process can swap a
directory in during the call). A union is the error: there is no separate kind
type, no error record and no helper over errors. `OtherOs(Int)` keeps the
platform's errno, which differs between macOS and Linux, and every decoder
turns a code its union does not name into `OtherOs` of the code negated, so a
disagreement between the runtime and the library is visible and never a crash.
The native codes are named in `src/common/codegen/runtime/fs.brp`. The language
README's [I/O overview](../README.md#effects-and-io) shows where the library
fits beside `print` and the other effects, and
[FILESYSTEM_DECISIONS.md](../FILESYSTEM_DECISIONS.md) records why it is shaped
this way. The text of a variant is fixed (`"no such file"`, `"permission
denied"`), never `strerror` text.

| Module (`io/fs/…`) | Operations | Error | Variants |
| --- | --- | --- | --- |
| `read` | `read_text`, `fold_lines` | `ReadError` | `NotFound` `PermissionDenied` `NotADirectory` `IsADirectory` `FileTooLarge` `InvalidUtf8` `OtherOs` |
| `write` | `write_text` | `WriteError` | `NotFound` `PermissionDenied` `AlreadyExists` `NotADirectory` `IsADirectory` `DirectoryNotEmpty` `NotARegularFile` `ReadOnlyFilesystem` `NoSpace` `FileTooLarge` `OtherOs` |
| `entry` | `entry_kind`, `Entry`, `EntryKind` | `EntryError` | `PermissionDenied` `OtherOs` |
| `list` | `list_directory` | `ListError` | `NotFound` `PermissionDenied` `NotADirectory` `InvalidUtf8` `OtherOs` |
| `create_directory` | `create_directory`, `create_directories` | `CreateDirectoryError` | `NotFound` `PermissionDenied` `AlreadyExists` `NotADirectory` `ReadOnlyFilesystem` `NoSpace` `OtherOs` |
| `remove_file` | `remove_file` | `RemoveFileError` | `NotFound` `PermissionDenied` `NotADirectory` `IsADirectory` `ReadOnlyFilesystem` `OtherOs` |
| `remove_directory` | `remove_directory` | `RemoveDirectoryError` | `NotFound` `PermissionDenied` `NotADirectory` `DirectoryNotEmpty` `ReadOnlyFilesystem` `OtherOs` |
| `remove_tree` | `remove_directory_tree` | `RemoveTreeError` | `NotFound` `PermissionDenied` `NotADirectory` `IsADirectory` `DirectoryNotEmpty` `ReadOnlyFilesystem` `CrossesDevices` `ChangedDuringRemoval` `OtherOs` |
| `rename` | `rename` | `RenameError` | `NotFound` `PermissionDenied` `NotADirectory` `IsADirectory` `DirectoryNotEmpty` `ReadOnlyFilesystem` `NoSpace` `CrossesDevices` `OtherOs` |
| `temporary_directory` | `with_temporary_directory` | `TemporaryDirectoryError` | `NotFound` `PermissionDenied` `NotADirectory` `IsADirectory` `DirectoryNotEmpty` `ReadOnlyFilesystem` `NoSpace` `CrossesDevices` `ChangedDuringRemoval` `InvalidPrefix` `OtherOs` |

`Union.Variant` names a variant through its union, so two unions that both have
a `NotFound` can be imported together:

```blorp
import:
    io/fs/read: ReadError, read_text
    path: Path

-- A missing file is no failure here; any other result stays.
func settings(path: Path) -> Result[String, ReadError]:
    result = path.read_text()
    match result:
        Err(ReadError.NotFound): Ok("")
        _: result
```

A caller that mixes operations writes its own error union and wraps with a
`match` or a lambda (a constructor is not a function value).

- `read_text(path) -> Result[String, ReadError]` reads to end of file, so a
  file that changes size is read as it is, and validates UTF-8. A directory is
  `IsADirectory`; interrupted `open` and `read` calls are retried. A FIFO
  blocks until its writer closes. There is no size limit: reading `/dev/zero`
  exhausts memory and the allocation aborts, an infrastructure exception.
- `write_text(path, text) -> Result[Void, WriteError]` replaces the file
  atomically: the text goes into a new file beside the target, named
  `.blorp-tmp-<pid>-<counter>`, which is flushed and then renamed over the
  target, so readers see the old contents or the new, never a mix, even after
  a crash. The flush orders the contents before the rename (`fsync` on Linux,
  `F_BARRIERFSYNC` on macOS, falling back to `fsync` where the file system
  lacks it); it does not force them to stable storage, and a failed flush is
  never retried. An `Err` before the rename leaves the target unchanged and
  removes the new file; an `Err` after it, which only the directory flush can
  give, means the target holds the old contents or the new. A symlink is
  written through: its final target is replaced in that target's own
  directory and the link stays a link. A dangling link is `NotFound` and
  creates nothing; a loop is `OtherOs`. A replaced file keeps its mode and,
  where permitted, its owner and group, or its group alone; a new file gets
  0666 narrowed by the umask. A read-only file is `PermissionDenied`, though
  `rename` alone would replace it. A path ending in `/` names a directory,
  which is never written: it is `IsADirectory` when it names one or a link to
  one, `NotADirectory` when it names anything else, and `NotFound` when
  nothing is there; any other failure to look it up is reported as for any
  path. Limits:
  - a hard link to the old file keeps the old contents;
  - extended attributes and ACLs are not copied;
  - a link re-pointed between resolving it and the rename is not detected;
  - a writable file in a directory this process cannot write is
    `PermissionDenied`, because the new file is created in that directory;
  - a crash can leave a hidden `.blorp-tmp-*` file beside the target;
  - a busy executable (ETXTBSY) or a bind-mounted target (EBUSY) is
    `OtherOs`;
  - a directory without read permission gives an `Err` after a rename that
    succeeded, because the directory flush opens it for reading;
  - writing past `RLIMIT_FSIZE` raises SIGXFSZ, which ends the process unless
    the program ignores that signal; a library does not change signal
    dispositions.
- `entry_kind(path) -> Result[Option[EntryKind], EntryError]` uses `lstat`, so
  a link is never followed. A missing path, or a file used as a directory, is
  `Ok(None)`; there is no `exists` that returns a Bool. `EntryKind` is `File`,
  `Directory`, `Symlink` or `Other`.
- `list_directory(path) -> Result[List[Entry], ListError]` lists a directory,
  sorted by name bytes, with `.` and `..` omitted. An `Entry` is a `name`, a
  String, and its own `EntryKind`, so a link in the listing is `Symlink`; a
  link given as the path is followed. A name that is not UTF-8 makes the whole
  listing `InvalidUtf8`, and an entry removed while the directory is read is
  left out.
- `create_directory(path)` makes one directory whose parent exists. An existing
  path of any kind is `AlreadyExists` and a missing parent `NotFound`;
  `missing/` creates `missing`, while `file/` for an existing file is
  `NotADirectory` on macOS and `AlreadyExists` on Linux.
  `create_directories(path)` makes each missing component. It succeeds on an
  existing directory, a link to one, or `/`, and when another process creates
  a component first. It fails with `NotADirectory` for a file in the middle
  and `AlreadyExists` for a file or dangling link at the end.
- `remove_file(path)` removes a file or link, never what a link names; a
  directory is `IsADirectory` on both platforms. `remove_directory(path)`
  removes an empty directory; one with entries is `DirectoryNotEmpty`.
  `rename(source, destination)` replaces a file, or an empty directory, at the
  destination. A file renamed onto a directory is `IsADirectory` (`EISDIR`), a
  destination directory with entries is `DirectoryNotEmpty`, and a different
  device is `CrossesDevices`. The error does not say which path is at fault:
  the caller has both.
- `remove_directory_tree(path)` removes a directory and everything in it,
  never through a link and never past the device it starts on. Only a real
  directory is a root: a file or a link, even to a directory, is
  `NotADirectory`, after trailing slashes are stripped. A final `.` or `..` is
  `OtherOs` before any system call, and a missing path is `NotFound`. A mount
  point inside the tree, a root that is a mount point and `/` are
  `CrossesDevices`; a bind mount of the same file system is entered and
  emptied, as by `rm -rf`. `ChangedDuringRemoval` means another process moved
  a directory during the walk. The first failure stops the walk and what was
  removed stays removed. An empty root that cannot be searched (mode 0400) is
  `PermissionDenied`, and so is a child that cannot be opened (mode 000)
  unless it is empty.
- `with_temporary_directory(parent, prefix, body, on_error)` makes a fresh
  directory (mode 0700) directly in `parent`, runs `body(directory)` with its
  `Path` and removes the directory and its contents before returning. `prefix`
  is a String; one that contains a NUL or a `/` is `InvalidPrefix`, and macOS
  replaces every trailing `X`. It is generic in the body's error type:
  `on_error` turns its own `TemporaryDirectoryError`, for creating and removing
  alike, into that type (`pure func(error: TemporaryDirectoryError) -> String:
  "${error}"` for a `String` error). The converter must be pure, so a plain
  `func` lambda is rejected. The result is the body's `Err`, else the
  removal's `Err`, else the body's `Ok`, so a body error hides a failed
  removal. A failed removal does not name the directory; the body was given
  its path. A signal, `abort()` or a stack overflow can still leave the
  directory behind.
- `fold_lines(path, initial, step, on_error)` folds `step` over a file's lines
  in order, reading a block at a time, so memory follows the longest line and
  never the file. It is generic in the fold's accumulator `T` and error `E`:
  `step: (T, String) -> Result[T, E]` takes the accumulator and the next line,
  and `on_error` converts this library's own `ReadError`, as in
  `with_temporary_directory`. A line ends at LF and one CR just before it is
  removed; a last line without LF counts and an empty file has no lines. The
  first `Err` from `step` stops reading and is the result. A failure to open or
  read is the result too: a directory is `IsADirectory`, a line that is not
  UTF-8 is `InvalidUtf8`, and a failed read returns none of its block's lines,
  though the steps already taken stay taken. The file is opened as `read_text`
  opens it and closed before `fold_lines` returns on every path the program
  controls; no descriptor reaches the caller, so none can be closed twice or
  read after its close. A FIFO blocks until a line arrives or its writer
  closes. `step` borrows its accumulator, so appending to a List in `step`
  copies it on every line; to collect every line, use `read_text`.

  ```blorp
  import:
      io/fs/read: ReadError, fold_lines
      path: Path
      string: String methods

  union ScoreError:
      Unreadable(ReadError)
      NotANumber(String)

  pure func add_score(total: Int, line: String) -> Result[Int, ScoreError]:
      match line.parse_int():
          Some(score): Ok(total + score)
          None: Err(NotANumber(line))

  -- "3\r\n4\n5" gives Ok(12). "3\nx\n5" gives Err(NotANumber("x")), and the
  -- fold stops reading at "x". A missing file gives Err(Unreadable(NotFound)).
  func total_score(path: Path) -> Result[Int, ScoreError]:
      fold_lines(path, 0, add_score, pure func(error: ReadError) -> ScoreError: Unreadable(error))
  ```

The runtime C is tested by `test/runtime/fs_suite.brp`, and the examples
`test/e2e/fixtures/fs/read.brp`, `lines.brp`, `write.brp` and `directories.brp`
run the library through ordinary mains. The harness runs `lines.brp` with at
most 256 open descriptors, so a fold that left its file open would fail its
1,000 early stops and 300 failed reads on every machine.

### Paths

`Path` is an opaque type over a String spelling: never empty and never holding
NUL. `to_path(text)` is the only way to make one and returns `Err(Empty)` or
`Err(ContainsNul)` (`PathError`, with fixed text) otherwise; nothing else is
checked and nothing is normalized. Only ASCII `/` separates components, and
these functions do no filesystem access, symlink resolution, case folding or
Unicode normalization. A string literal never becomes a `Path`.

Equality is byte-wise on the spelling, so `a//b` and `a/b` are different paths,
and so are the NFC and NFD spellings of one name. `Path` is `Stringable` (its
spelling), `Equatable` and `Hashable` (byte equality of the spelling), and
`Addable`, where `+` concatenates the spellings exactly as String `+` does (`a`
+ `b` is `ab`, never `a/b`). It is not `Orderable`. Its functions are lexical:

- `join(base, child)` puts `child` under `base`, even when `child` is absolute:
  `/a` and `/b` give `/a/b`. This is not Rust's or Python's join, where an
  absolute child replaces the base, and it does not clean: exactly one `/`
  joins the parts, the base's trailing separators (root stays `/`) and the
  child's leading ones are dropped, and `..`, `.` and repeated separators
  inside either part stay as written. A child of only separators gives the
  base. A caller that wants the other behaviour asks `is_absolute` first.
- `normalize(path)` removes empty and `.` components and resolves `..` against
  a preceding ordinary component. Leading relative parents survive; absolute
  paths cannot move above root. It never gives an empty spelling: a relative
  path that cancels completely is `.`, and root is `/`.
- `parent(path)` is total: `a` is `.` and `/` is `/`. It ignores trailing
  separators and keeps interior spelling.
- `name(path)` is the last component ignoring trailing separators (`a/b/` is
  `b`); `None` for `/`, `.` and `..`.
- `stem(path)` and `extension(path)` split the name at its last dot that does
  not begin it: `x.test.brp` is `x.test` and `brp`, `.hidden` has no extension,
  `a.` has the empty extension, and `...` has stem `..` and the empty extension. Both are `None` where `name` is.
- `is_absolute(path)` is true when the spelling starts with a separator.
- `ends_in_separator(path)` is true when the spelling ends with a separator: `a/`
  and `/` do, `a` does not. Such a path names a directory.
- `is_within(path, root)` compares components, never bytes; both must be
  absolute or both relative, `.` components and repeated separators are
  ignored, and a `..` after the root's components makes the answer `False`
  because nothing is resolved. Lexical only: it does not resolve symlinks, so
  it is not a sandbox check.

### Test registration

`test: TestSuite` holds `description: String` and
`tests: List[(String, () -> Bool)]`. Declare a `TESTS: TestSuite` constant with
named callback entries in each suite file itself; a `TESTS()` function or an
imported `TESTS` is rejected. `blorp compile --test-suite` accepts one or more such files: its
entry passes each file's constant to `run_suite_result` in command-line order
and returns `suites_exit_status` of the counts. Both pure and impure callbacks
run in registration order, including entries after a False result. Empty suites
pass. `run_suite_result` prints results and returns `TestCounts { passed, failed }`;
`suites_exit_status` returns 0 when no suite failed and 1 otherwise, and
`run_suite` does the same for one suite. See the
[text suite](../test/unit/test_common/test_utils/test_text.brp).

## Process execution

`io/process` runs a program, waits for it and keeps what it printed. The prelude
and compiler source do not import it. [PROCESS_DECISIONS.md](../PROCESS_DECISIONS.md)
records the design and its decisions.

```blorp
import:
    io/process:
        Command, Exit(Exited, Signaled, TimedOut), Captured, CaptureError, FindProgramError,
        OutputError, command, capture, output, find_program
    path: Path
    result: Result methods

union CommitError:
    GitMissing(FindProgramError)
    GitFailed(OutputError)

func current_commit(repository: Path) -> Result[String, CommitError]:
    git: Path ?= find_program("git").map_err(pure func(error: FindProgramError): GitMissing(error))
    output({ command(git, ["rev-parse", "HEAD"]) | directory = Some(repository) })
        .map_err(pure func(error: OutputError): GitFailed(error))
```

Each operation has its own error union, and none holds the program or the
directory: the caller has its `Command`. A caller that mixes operations writes
its own error type, as `CommitError` does; a constructor is not a function
value, so the wrapping is a `match` or a lambda.

- `command(program, arguments)` builds a `Command`; change its `directory`,
  `environment` (`Some` sets a variable, `None` removes it, the rest is
  inherited), `stdin` (`None` is `/dev/null`) and `timeout_ms` by record
  update. `program` is a `Path`, such as the one `find_program` returns, and
  `directory` an `Option[Path]`. There is no shell and no PATH search, and
  every argument is literal. A relative program is found from `directory`.
- `capture(command)` returns `Ok(Captured { exit, stdout, stderr })` for
  every way the child can end: `Exited(status)`, `Signaled(signal)` or
  `TimedOut`; its error is a `CaptureError`. `output(command)` returns stdout
  after `Exited(0)`, `CaptureFailed(error)` when `capture` failed, and
  otherwise `Unsuccessful(captured)` in an `OutputError`, so `?=` over `output` stops a sequence
  at the first failure with everything the command printed.
- The child never outlives the call: when it exits or the deadline passes,
  its process group is killed and only what is already buffered is read, so a
  grandchild holding a pipe open cannot hang the call. A process that left the
  group, through `setsid` for example, is outside this guarantee, and at most
  16 MiB more of its output per stream is read.
- `stdin` is written while both outputs are read; a child that exits without
  reading it is not an error. SIGPIPE is blocked in the calling thread only
  while writing, the SIGPIPE a write raised is consumed, and no signal
  disposition changes. A timeout of 0 or less is `TimedOut` at once, without
  starting the program.
- Output must be UTF-8: otherwise the error is `StdoutNotUtf8(exit)` or
  `StderrNotUtf8(exit)`. After `Signaled` or `TimedOut`, up to three bytes of a
  character cut off at the end of a stream are dropped first.
- `CaptureError` has no program in it. `InvalidVariableName` (an empty name
  or one with `=`) and `ContainsNul` (in an argument or the environment; a
  `Path` holds none) are found before any system call. A directory the child cannot
  enter is `DirectoryFailed(cause)`. `NotExecutable` is ENOEXEC, such as a
  script without `#!`; every other launch failure is `LaunchFailed(cause)`. A
  cause is a `SystemCallError`: `NotFound`, `PermissionDenied`, `NotADirectory`
  or `OtherOs(errno)`, so a missing program is `LaunchFailed(NotFound)`.
- SIGCHLD must keep its default disposition, which a Blorp program cannot
  change. If foreign code has changed it, `capture` is
  `LaunchFailed(OtherOs(ECHILD))` before anything starts.
- `find_program(name)` returns the first absolute PATH entry holding a regular
  file of that name the process may execute, as "entry/name". Empty and
  relative entries, and entries that are not UTF-8, are skipped, so the current
  directory is never searched. It returns a `Path`, or a `FindProgramError`:
  `NotOnPath`, which a name that is empty or contains `/` is without a search,
  or `NameContainsNul`.
- A reply from the runtime that the library cannot decode is a defect in the
  runtime, not an outcome: the program prints
  "blorp: process runtime defect: ..." and aborts.
- `exit.succeeded()` is `Exited(0)`. Every error union is `Stringable`
  with fixed text and no program or directory: `Unsuccessful` is "exited 2"
  followed by the child's stderr, and `DirectoryFailed(cause)` is "cannot
  enter the directory: <cause>". A `SystemCallError` is worded like the `io/fs/` errors
  words the errno.
