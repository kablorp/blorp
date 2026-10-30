# Blorp 2 standard library

These modules are compiled by Blorp 2 for input programs. They are separate
from the legacy library at `standard_library/src/`. All active Blorp 2 tests
use this target library. The
pinned Blorp2 compiler uses this target library when compiling compiler source.

The directory was renamed from `standard_library_temp` on 2026-10-18. Dated
benchmark reports and retained raw evidence keep the historical path to preserve
measurement provenance; current commands use `blorp_2/standard_library`.

The library root contains two designated foundation modules:

- `_base.brp` owns Int, Float, String, Void, List, Bool, Option, Result, the
  `Orderable` and `Hashable` traits and the arithmetic traits `Addable`,
  `Subtractable`, `Multipliable`, `Divisible`, `Modulable` and `Negatable`. It
  is the only module that may declare builtin types. Any module may import it
  as `_base`.
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
each returns `Self`.

`bool.brp` defines pure, ordinary `not`, `and` and `or`; select them explicitly
with `bool: not, and, or` for direct calls and UFCS. Both binary arguments are eager;
use an explicit `match` to skip evaluation. The prelude leaves these names available
for user helper declarations and selections of their own ordinary functions.
They import only other library modules and `_base`, never user modules.

For example, `42.add(1).to_string().length()` needs no imports. Direct calls
still require named imports such as `int: add`; `add` selected from both `int`
and `string` names the one Addable family. IO remains explicit.
Int implements `Orderable` with one signed64 `less_than` builtin and the trait's
defaults; `min` and `max` are ordinary pure functions. `not_equals` uses the canonical
trait default. Imported `INT_MIN`
and `INT_MAX` are closed scalar literals, with no runtime global storage.
The [imports design](../README.md#local-modules) defines the full rules.

`system.brp` records its accepted upstream revision and source SHA256.
Its explicit `get_current_directory()` import returns `Result[String, String]`:
an owned nonempty absolute UTF-8 path or an owned valid-text error.
Neither branch prints. The native helper uses the target String ABI.

`int.brp` records the upstream revision and SHA256 used for its adaptation of
[`standard_library/src/int.brp`](../../standard_library/src/int.brp). Its
arithmetic implementations have builtin bodies except `negate`, which is
`subtract(0, value)` and so wraps `INT_MIN` to itself; `to_string` is concrete.
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
The compiler's Int-keyed map uses this method for home slots and still compares
keys by equality when probing collisions.

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
No constant-stack or COW claim is implied.

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
| `sort_by[T, Key: Orderable](values, key: pure (T) -> Key) -> List[T]` | Stable ascending key order; equal keys retain input order. A key order that is not total, such as Float NaN, still yields a permutation, in an unspecified order. |

Inputs are borrowed; returned managed values retain independent ownership and
older aliases remain valid. Predicate/key callbacks may capture immutable data.
The sort key may run more than once per element. Take/drop/remove/reverse temporarily copy O(n log n) List slots
with O(log(n + 1)) stack. Find/all visit at most n elements in input order,
with logarithmic stack and short-circuiting. Sort uses a temporary merge
implementation. No COW or constant-stack claim follows from availability.
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

The List update names match the unchanged host library because the same compiler source
must build against both libraries. The internal `list.set` builtin implements the
no-op-on-invalid update; checked `set_index` is an ordinary function. The desired
later rename to checked `set` and no-op `set_or_keep` must update both libraries
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
layout follows the unions' declaration order. Each adapter records its upstream
provenance. FFI remains inactive.

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
    ./foo_ops: Foo methods
```

`Foo methods` requires the exact Foo type independently visible in the
caller. It imports no type or constructors and cannot make bare function calls
available. A module offers only the types it declares, so `int: Int` is
rejected and `int: Int methods` uses `int`'s functions on Int; no module
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
