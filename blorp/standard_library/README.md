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
  `Orderable` and `Hashable` traits and the arithmetic traits `Addable`,
  `Subtractable`, `Multipliable`, `Divisible`, `Modulable` and `Negatable`,
  plus the checked-arithmetic error `MathError`. It is the only module that may
  declare builtin types. Any module may import it as `_base`.
- `prelude.brp` imports the base types and the operation modules' methods. It
  is the only implicit import: application roots and ordinary user helper
  modules receive its selections, and it cannot be imported explicitly.

Library modules receive nothing implicitly. Each one imports what it uses,
including base types, for example `_base: Int, Bool(True, False)` in `int.brp`.
`traits.brp` owns canonical Equatable and imports only Bool and its constructors
from _base. The prelude selects that trait; operation modules provide written
Int/Float/String/List implementations. Equality imports name this one family,
so aliases and contextual callable references dispatch by the actual receiver.
`Orderable` requires `less_than` and defaults `greater_than`, `less_than_or_equal`
and `greater_than_or_equal` from it; the defaults assume a total order. A library
module may implement a trait declared in `_base`, or the canonical Equatable, for
a type declared in `_base`: `int.brp`
and `float.brp` implement Equatable, Orderable and the six arithmetic traits,
`string.brp` implements Equatable and Addable, and `list.brp` implements Equatable.
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
defaults; `min` and `max` are ordinary pure functions. `not_equals` uses the canonical
trait default. Imported `INT_MIN`
and `INT_MAX` are closed scalar literals, with no runtime global storage.
The [imports design](../README.md#modules-imports-and-the-prelude) defines the full rules.

`system.brp`'s explicit `get_current_directory()` import returns `Result[String, String]`:
an owned nonempty absolute UTF-8 path or an owned valid-text error.
Neither branch prints. The native helper uses the target String ABI.

`int.brp` adapts the legacy
[`standard_library/src/int.brp`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/int.brp). Its
arithmetic implementations have builtin bodies except `negate`, which is
`subtract(0, value)` and so wraps `INT_MIN` to itself; `to_string` is concrete.
Its six `_checked` functions are ordinary pure functions returning
`Result[Int, MathError]`. `add_checked` and `subtract_checked` compare the
operands with `INT_MIN` and `INT_MAX` without wrapping; `multiply_checked`
detects a wrapped product by dividing it back; `divide_checked`,
`remainder_checked` and `negate_checked` test for 0, -1 and `INT_MIN`. The
prelude selects neither MathError nor its cases, so `Overflow` and
`DivisionByZero` stay free for user declarations; naming the type or a case
requires `_base: MathError(DivisionByZero, Overflow)`.
The Float adapter implements the same six traits for Float64, with `negate` as
`multiply(value, -1.0)` so that the sign of zero flips, plus concrete
`to_string`, `copysign`, `equals`, `is_nan`, `is_finite` and `abs`. `is_nan`
uses ordinary self-equality, and `is_finite` compares
ordinary self-subtraction with zero; neither requires a builtin label.
Float implements `Orderable`: every comparison with NaN is false, so
it writes its own `less_than_or_equal` and `greater_than_or_equal`.
`Hashable` is an ordinary foundation trait with the pure method
`hash(value: Self) -> Int`. The prelude supplies the trait name and Int's method
route; direct calls use `int: hash`. Int's written implementation returns its
value unchanged, including negative values and `INT_MIN`. Hashes may be any
signed Int. For values compared by equality, equal values must have equal hashes;
distinct values may collide. Hashable has no supertraits and is never derived.
String writes its hash in `string.brp` (a fold of its bytes from a fixed basis,
unseeded) and Bool in `bool.brp` (`False` 0, `True` 1). The compiler's
`Dict[K, V]` (`K: DictKey`, a bundle of `Hashable + Equatable`) uses this method
for home slots and still compares keys by equality when probing collisions.

`Int` and `Float` are declared once in `_base.brp`. Other
declarations are enabled only as their features enter the supported subset.
The original modules are preserved in the legacy
[standard_library/src](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/).

Pass `blorp/standard_library` explicitly as the argument to `--library-root`. Bare `int: add` imports resolve here; relative
imports still resolve beside their importer. There is no host-library fallback.

`io.brp` adapts the legacy
[`standard_library/src/io.brp`](https://github.com/kablorp/blorp/blob/ee9e001c6de8911ee486fd992419bef5bc628e8b/standard_library/src/io.brp). Its active
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

`dict.brp` declares `trait DictKey: Hashable + Equatable` and the opaque
`Dict[K: DictKey, V]`, an insertion-ordered map over parallel Lists and an
open-addressing index. Int, String and Bool implement `DictKey` with a bodyless
`implements DictKey for T`; a record or opaque key writes its own `Hashable` and
`Equatable` first, except that a record or union whose fields are all Equatable
already has `==` and writes only `Hashable`. A key with several parts hashes them
with `combine_hash(seed, value) = (seed + value) * 1099511628211`, wrapping:
start from 0 and combine every part in order, the first included, because
combining two parts directly is symmetric. A List of Hashable elements is
Hashable, combining its length and then each element in order, and a List of keys is a
key; both live in `dict.brp` beside `combine_hash`, since `list.brp` is imported
by `dict.brp`. The prelude imports `dict: Dict`, so
the type and its receiver methods are implicit; `empty` and `dict` are
reached as `import: dict as D`. All functions are pure.

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
| `empty[K: DictKey, V]() -> Dict[K, V]` | No entries. |
| `dict[K: DictKey, V](initial_capacity) -> Dict[K, V]` | Room for `initial_capacity` entries before the index grows; at most 1,048,576 are reserved, a larger or negative count is only a hint. |
| `get(self, key) -> Option[V]`, `get_or(self, key, default) -> V`, `contains(self, key) -> Bool` | O(1) average lookups; a missing key is `None` or the eagerly evaluated default. |
| `set(self, key, value) -> Dict[K, V]` | Insert, or replace the value and keep the key's position. O(1) amortized. |
| `remove(self, key) -> Dict[K, V]` | Without the key, order of the rest kept; unchanged when absent. O(1) amortized. |
| `keys(self) -> List[K]`, `values(self) -> List[V]`, `entries(self) -> List[(K, V)]` | Live entries in first-insertion order; a key removed and set again goes last. |
| `length(self) -> Int`, `is_empty(self) -> Bool` | The live entry count, in O(1). |

`Equatable` for `Dict[K: DictKey, V: Equatable]` compares lengths, then looks up
each key of one Dict in the other, whatever the order. A Dict is neither
`Hashable` nor a `DictKey`, and Float is not a key. An update to a uniquely owned
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

`io.print_error(String) -> Void` concretely adapts the host Stringable API.
It borrows its input, writes counted bytes to stderr once, and attempts LF only
following a full transfer; short writes (including EINTR) stop without retry.
The host attempts LF after short writes as well. Neither API reports delivery.

### The fs module

`fs.brp` is the typed filesystem library; import it explicitly. It declares
the fixed unions `IOErrorKind` and `EntryKind`, the records `IOError` and
`Entry`, the pure `describe` and `default_if_not_found`, and the impure
operations below, each returning a `Result` whose error is an `IOError`. Its
natives return Int codes (or a list or String) that private decoders turn
into kinds and entries; the codes are named in `src/compile/runtime/fs.brp`. The
language README's [I/O overview](../README.md#effects-and-io) shows where it
fits beside `print` and the other effects, and
[FILESYSTEM_DECISIONS.md](../FILESYSTEM_DECISIONS.md) records why the library
is shaped this way and what is still open.

- `read_text(path) -> Result[String, IOError]` reads to end of file, so a file
  that changes size is read as it is, and validates UTF-8. A directory is
  `IsADirectory`; a NUL in the path is `PathContainsNul` before any system
  call; interrupted `open` and `read` calls are retried. A FIFO blocks until
  its writer closes. There is no size limit: reading `/dev/zero` exhausts
  memory and the allocation aborts, an infrastructure exception.
- `write_text(path, text) -> Result[Void, IOError]` replaces the file
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
- `entry_kind(path) -> Result[Option[EntryKind], IOError]` uses `lstat`, so a
  link is never followed. A missing path, or a file used as a directory, is
  `Ok(None)`; there is no `exists` that returns a Bool.
- `list_directory(path) -> Result[List[Entry], IOError]` lists a directory,
  sorted by name bytes, with `.` and `..` omitted. An `Entry` is a `name` and
  its own `EntryKind`, so a link in the listing is `Symlink`; a link given as
  the path is followed. A name that is not UTF-8 makes the whole listing
  `InvalidUtf8`, and an entry removed while the directory is read is left out.
- `create_directory(path)` makes one directory whose parent exists. An existing
  path of any kind is `AlreadyExists` and a missing parent `NotFound`;
  `missing/` creates `missing`, while `file/` for an existing file is
  `NotADirectory` on macOS and `AlreadyExists` on Linux.
  `create_directories(path)` makes each missing component. It succeeds on an
  existing directory, a link to one, or `/`, and when another process creates
  a component first. It fails with `NotFound` for the empty path,
  `NotADirectory` for a file in the middle and `AlreadyExists` for a file or
  dangling link at the end. Every failure names the caller's path.
- `remove_file(path)` removes a file or link, never what a link names; a
  directory is `IsADirectory` on both platforms. `remove_directory(path)`
  removes an empty directory; one with entries is `DirectoryNotEmpty`.
  `rename(source, destination)` replaces a file, or an empty directory, at the
  destination, and its error carries both paths in `path` and `destination`.
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
- `with_temporary_directory(parent, prefix, body, io_error)` makes a fresh
  directory (mode 0700) directly in `parent`, runs `body(directory)` and
  removes the directory and its contents before returning. It is generic in
  the body's error type: `io_error` turns its own `IOError` into that type
  (`describe` for a `String` error,
  `pure func(error: IOError) -> IOError: error` for `IOError`). The converter
  must be pure, so a plain `func` lambda is rejected. The result is the body's
  `Err`, else the removal's `Err`, else the body's `Ok`, so a body error hides a
  failed removal. A failure to create the directory names `parent`; a failed
  removal names the directory itself, the one exception to the rule below. A
  signal, `abort()` or a stack overflow can still leave the directory behind.
- `fold_lines(path, initial, step, io_error)` folds `step` over a file's lines
  in order, reading a block at a time, so memory follows the longest line and
  never the file. It is generic in the fold's accumulator `T` and error `E`:
  `step: (T, String) -> Result[T, E]` takes the accumulator and the next line,
  and `io_error` converts this library's own `IOError`, as in
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
      fs: IOError, fold_lines
      string: String methods

  union ScoreError:
      Unreadable(IOError)
      NotANumber(String)

  pure func add_score(total: Int, line: String) -> Result[Int, ScoreError]:
      match line.parse_int():
          Some(score): Ok(total + score)
          None: Err(NotANumber(line))

  -- "3\r\n4\n5" gives Ok(12). "3\nx\n5" gives Err(NotANumber("x")), and the
  -- fold stops reading at "x". A missing file gives Err(Unreadable(...NotFound)).
  func total_score(path: String) -> Result[Int, ScoreError]:
      fold_lines(path, 0, add_score, pure func(error: IOError) -> ScoreError: Unreadable(error))
  ```
- `IOError` holds the caller's `path`, an optional `destination` for
  two-path operations, and an `IOErrorKind`: `NotFound`, `PermissionDenied`,
  `AlreadyExists`, `NotADirectory`, `IsADirectory`, `DirectoryNotEmpty`,
  `NotARegularFile`, `ReadOnlyFilesystem`, `NoSpace`, `FileTooLarge`,
  `CrossesDevices`, `PathContainsNul`, `InvalidUtf8`, `ChangedDuringRemoval`
  and `OtherOs(Int)`, which keeps the platform's errno. The path is the one
  the caller passed, so `x: permission denied` does not say whether `x` or a
  parent refused, except for the cleanup failure above.
- `describe(error)` gives `"<path>: <phrase>"` with fixed text per kind, never
  `strerror` text. `default_if_not_found(result, fallback)` turns `NotFound`
  into `Ok(fallback)` and leaves every other result alone.

The runtime C is tested by `test/runtime/fs_suite.brp`, and the examples
`test/e2e/fixtures/fs/read.brp`, `lines.brp`, `write.brp` and `directories.brp`
run the library through ordinary mains. The harness runs `lines.brp` with at
most 256 open descriptors, so a fold that left its file open would fail its
1,000 early stops and 300 failed reads on every machine.

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

The byte scan/materialization is linear, and List take and String joining build
their results in one pass.

### Test registration

`test: TestSuite` holds `description: String` and
`tests: List[(String, () -> Bool)]`. Declare a `tests: TestSuite` constant with
named callback entries in each suite file itself; a `tests()` function or an
imported `tests` is rejected. `--test-suite` accepts one or more such files: its
entry passes each file's constant to `run_suite_result` in command-line order
and returns `suites_exit_status` of the counts. Both pure and impure callbacks
run in registration order, including entries after a False result. Empty suites
pass. `run_suite_result` prints results and returns `TestCounts { passed, failed }`;
`suites_exit_status` returns 0 when no suite failed and 1 otherwise, and
`run_suite` does the same for one suite. See the
[text suite](../test/unit/test_utils/test_text.brp).

## Process execution

Explicitly import `process: run_to_files`; the prelude and compiler source do not
import it. This is a target-only impure operation:

```blorp
func run_to_files(
    program: String, arguments: List[String],
    stdout_path: String, stderr_path: String, timeout_ms: Int,
) -> Result[Int, String]
```

`program` is an explicit executable path; arguments exclude argv[0]. No shell,
PATH search or quoting interpretation occurs. Empty, spaced and Unicode
arguments are literal. The child inherits cwd/environment and reads stdin from
`/dev/null`. The timeout must be positive; paths and arguments must contain no
embedded NUL. Validation precedes capture creation.

The operation exclusively creates two new regular files; existing destinations,
including symlinks and FIFOs, fail without truncation. On failure a newly-created
partial capture may remain; the caller owns its directory and cleanup.
Ordinary exits, including nonzero and 127, produce `Ok(status)`. Setup/exec,
signal, timeout and cleanup failures produce `Err(message)`, never fabricated
exit codes. A monotonic deadline covers exec startup and waiting and initiates
forced direct-child cleanup; OS cleanup latency is not bounded. The direct child
is terminated and reaped; group SIGKILL is a best-effort attempt before reaping
the leader, without claiming descendant termination. macOS can return EPERM for
a group containing only its already-exited leader. Direct-child signal/wait
errors remain failures. Child-process ownership
requires the default SIGCHLD disposition without SA_NOCLDWAIT; unsupported
dispositions are rejected before creating files and are never modified.

Commands must wait for their own work: background writers, detached daemons and
grandchild supervision are outside this API. The first e2e driver passes explicit
`/usr/bin/env` argv to isolate child leak-check settings. Make owns temporary
directories and executable resolution; this API adds no environment, cwd,
temporary-directory or general process-handle framework.
