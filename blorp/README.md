# Blorp

Blorp is a pure-by-default functional language with algebraic data types,
pattern matching, traits and value semantics. Its compiler is written in
Blorp, compiles itself and emits C. Memory is managed by reference counting:
there is no garbage collector and no shared mutable state.

The compiler is in [`src/`](src/): `main.brp` dispatches each command to its
folder (`compile/`, and `format/` with the formatter), and `common/` holds
what the commands share (the front end, the analysis and code-generation
phases, and command-line reporting). Programs compile
against [`standard_library/`](standard_library/), whose
[README](standard_library/README.md) owns its API contracts. Tests are in
[`test/`](test/), and [`grammar.ebnf`](grammar.ebnf) is the formal grammar.
This file defines the supported language, the commands that build and test
it, the compiler's architecture and its measurement tools. The rules for
working on the compiler are in [AGENTS.md](AGENTS.md).

## Building and running

Every command runs from the repository root.

```sh
make -C blorp                  # build blorp/build/blorp and blorp/build/blorp-test from the seed
make -C blorp example          # compile, build and run test/test_compile/fixtures/return/zero.brp
```

The `blorp` command (`blorp/build/blorp`, also `bin/blorp`) has the commands
`compile`, `format` and `help`. `compile` takes the input and where to write the
C; the standard library is built into the binary:

```sh
bin/blorp compile input.brp -o output.c
clang -std=c11 -Wall -Wextra -Werror -pedantic -O0 output.c -o program -lm
./program
```

Without `-o` the C goes to the input's name with `.c` in the current directory.
`blorp help` and `blorp help COMMAND` print each command's options.
`--library-root DIRECTORY` compiles against that directory's library instead of the
embedded copy, as the tests and the compiler's own build do. The embedded copy
is the text of `blorp/standard_library` at the last `make -C blorp compiler`;
diagnostics name its files `<standard library>/list.brp`.
The exit status is 0 on success, 1 when the code needs fixing (a diagnostic, a
file that does not parse, a file `--check` would reformat), 2 for bad usage, 3
when a path could not be read or written, and 4 for a fault in blorp itself.
Every error has a
source location, an explanation and a help line. A rejected program writes no
C and leaves an existing output file as it was. Programs that use Float need
`-lm`. `BLORP_CC` selects the C compiler `make` uses (default `clang`).

```sh
make -C blorp test             # build the test compiler, run components and e2e
make -C blorp test-e2e         # e2e only, with the test compiler already built
make -C blorp test-target-components TARGET_COMPONENT_SOURCES=blorp/test/test_common/test_utils/test_text.brp
make -C blorp test INSTRUCTION_CHECK=on   # macOS: also hold retired-instruction ceilings
```

`make -C blorp test` links the test compiler, `blorp/build/blorp-test` (the C of
`blorp/build/blorp` with memory diagnostics), and runs the component suites and
native end-to-end cases with it. Every test target runs that build, and
`make -C blorp compiler` links it too. [`AGENTS.md`](AGENTS.md) owns
the test layout and gates; [Tests](#tests) describes `TestSuite`.

### Formatting

`blorp format` puts source files in the one canonical layout:

```sh
bin/blorp format                                  # every .brp file under the current directory
bin/blorp format blorp/src blorp/src/main.brp     # directories and files, rewritten in place
bin/blorp format --check blorp/src                # report, change nothing
bin/blorp format --exclude blorp/test/test_format/fixtures blorp/test
```

Each `PATH` is a `.brp` file or a directory, which is walked recursively in byte
order of entry name; with no `PATH` the current directory is walked. Walked
entries whose names start with `.` and walked symbolic links are skipped, but a
`PATH` written on the command line is always used. Paths are normalized, so
`blorp format --check .` prints `src/a.brp`, and a file reached from two paths is
processed once. `--exclude PATH`, which may repeat, removes a file, or a
directory and everything below it on component boundaries; an excluded path
that does not exist or lies outside every `PATH` is a usage error, and
"outside" is lexical: `../../x` is not under `..`. An empty path is a usage
error. Formatting rewrites only the files whose layout changes. `--check` prints
`path:line: would reformat` for each file that would change, at its first
changed line, and exits 1 if any would. A file that does not parse gets the
parser's diagnostic and is left as it was, and the command exits 1; the other
files are still processed. A bare `blorp format` from the repository root would
also rewrite sources that are unformatted on purpose (the layout fixtures'
inputs and a few must-fail fixtures): format the files you changed, or run
`make -C blorp format-check`, which checks the roots with the exclusions
listed in `blorp/Makefile`. Formatting reads a file on
its own, so it need not type-check. Patterns, types and declaration header lines never break, so
a comment inside one stops the formatter, which says where and leaves that
file unchanged; move the comment above the line. `make -C blorp test` runs that
check first, and `git config
blame.ignoreRevsFile .git-blame-ignore-revs` hides the commit that applied the
formatter from `git blame`.

The layout rules:

- Four-space indentation, lines wrapped at 100 columns. LF line endings and
  one final newline. A trailing comment is never moved, even past the width.
- Imports are sorted: library modules, then relative paths, each
  alphabetical. The names inside one selection keep their written order. A
  comment on an import's line, or directly above it, moves with it.
- A list of parameters, arguments, fields, elements or selections is on one
  line or has one item per line with a trailing comma. A final list literal,
  record literal or block lambda hugs the line when everything before it fits.
- A chain of two or more method calls always breaks, one call per line, one
  level deeper than its head. In a block header (`if`, `while`, `for`,
  `match`) the formatter wraps such a chain in parentheses. A chain of one
  call breaks only by the width rule, and interpolation holes never break.
  Field reads and a leading direct call belong to the head and do not count
  toward the two calls; `and`, `or` and `not` are ordinary calls.
- Parentheses are removed only where they wrap a whole value (a binding
  value, argument, element, condition, body's final value, record field or
  Dict entry value, or `?=` value) and added there only to break an operator
  chain. Every other pair stays as written.
- If any arm of a `match` is a block, every arm of that `match` is. An arm is
  a block when its body has more than one statement, its value does not fit on
  the pattern's line, or it holds an own-line comment.
- A `record` declaration always has one field per line.
- An own-line comment goes to the deepest open block whose source level does
  not exceed its own, so it keeps the nesting its author gave it.
- Two blank lines separate top-level declarations, except that a run of
  one-line constants keeps the one or no blank line it was written with.
  Inside a body at most one blank line stays.
- An `else:` block holding only an `if` is not rewritten to `else if`: the
  two are different trees and compile to different C.
- The formatter lexes and parses with the compiler's front end and prints the
  tree, so it never recognizes syntax on its own. The parse tree keeps
  parentheses and declaration starts for it, and comments and blank lines
  come from the source between nodes.

## The language

### Programs and main

```blorp
func main() -> Int:
    print("Hello, World!")
    0
```

This is [`effects/hello.brp`](test/test_compile/fixtures/effects/hello.brp). It prints
`Hello, World!` and exits 0.

A program has exactly one `main`, in its root file. It is not generic, takes
no parameters or one `List[String]`, and returns `Int` or `Void`. An `Int`
result is the exit status; a `Void` result exits 0. An omitted return
annotation means `Void`, so `func main():` is a Void entrypoint. `main` may be
`pure`. A `main` in another module is an ordinary function.

The argument list holds the executable name at index 0. Each argument is
checked for UTF-8 before `main` runs; an invalid one exits 1 with
`error: command-line argument is not valid UTF-8` and
`help: pass UTF-8 encoded arguments` on stderr.

### Source layout

A declaration starts at column 1. A block is indented deeper than its header,
by any amount. An indentation prefix is tabs only or groups of four spaces,
and a dedent must land on an open level. Blank and comment lines may appear
anywhere and have no layout meaning. Lines end in LF. CR is rejected, and so
are non-ASCII bytes outside String literals and documentation blocks.

`--` starts a comment that runs to the end of the line, except directly after
a value (a name, a literal, `void`, `)`, `]` or `}`), where it is rejected so
that `a--1` never reads as `a` and a comment. A line holding only `---` at
column 1 opens a documentation block, which the next such line closes.

An expression stays on one line, except that a line break inside an open
bracket continues it. A newline after an operator ends the expression, so wrap
a long expression in parentheses. A method chain may continue on lines that
start with `.`, at the same indentation or one level deeper, but an `if`,
`while`, `for` or `match` header cannot hold an indented chain ("a method chain
in a block header must end on its line"). Every bracketed, comma-separated
list admits a trailing comma.

Identifiers are ASCII letters, digits and `_`, not starting with a digit.
[`grammar.ebnf`](grammar.ebnf) lists the reserved words; declaring one reports
"`match` is a reserved keyword and cannot be used as a name". `fixed`,
`methods`, `tail_recursive`, `and`, `or` and `not` are ordinary names.

### Naming

The case of a declared name says what it is, and the compiler enforces it:

| Names | Form | Examples |
| --- | --- | --- |
| Types, variants, traits, type parameters | `CapitalizedCamelCase` | `ReadError`, `URLError`, `UInt8`, `T` |
| Module constants | `UPPER_SNAKE_CASE` | `MAX_DEPTH`, `TESTS`, `MAX` |
| Functions, methods, parameters, locals, captures, fields, import aliases | `lower_snake_case` | `read_text`, `utf8_valid`, `x1` |

Consecutive capitals are allowed, so `URLError` and `UInt8` stay valid. A single
capital word such as `MAX` or `T` fits both the first two forms. `_` is the
discard; no other name starts with an underscore, and underscores are never
doubled or trailing. Module paths such as `_base` are paths, not names. A
declared name in the wrong form is a parse error whose help gives the
converted name:

```text
error: a local is written in lower_snake_case
help: write `kind`
```

Conversion splits before a capital that follows a lowercase letter or digit and
before the last capital of a run followed by a lowercase letter, so `URLError`
becomes `url_error` and `UInt8` becomes `u_int8`. A name that is used is not
checked again, except that a field or method after a dot is lower_snake_case: `x.Foo`
is rejected ("fields and methods are lower_snake_case"). A bare name in a
pattern that starts with a capital is a variant, and one that no visible variant
has is an error, never a binding; any other bare name is a binding and is
checked as a local. An import alias shares the value namespace
with locals and parameters, so choose one that no local in the file uses.

A function, method or requirement parameter may be `_`, as a lambda parameter
can: `pure func second(_: Int, value: Int, _: Int) -> Int`. It takes an
argument and binds no name, any number of them may appear in one signature,
and using `_` in the body is an error ("`_` is not a value"). A discarded
parameter cannot have a function type; name it.

### Functions and purity

```blorp
pure func one() -> Int:
    1
pure func answer() -> Int:
    one()
func main() -> Int:
    answer()
```

This is [`pure/calls.brp`](test/test_compile/fixtures/pure/calls.brp); it exits 1. A
body is zero or more statements followed by a final expression, which is the
result; there is no `return`. Declarations may appear in any order, calls pass
exactly the declared number of arguments, and function names are unique
within a module.

A `pure func` may call only pure functions; a plain `func` may call either.
Purity is declared and checked, never inferred, and every body is checked,
including unreachable ones. A violation points at the callee and suggests
marking it pure or removing `pure` from the caller. Pure functions may mutate
their own local variables.

A `Void` function evaluates and discards its final expression, whatever its
type. A statement before the final expression must have type `Void`; bind or
return any other value.

`receiver.f(arguments)` calls `f(receiver, arguments)`. This is UFCS, the main
way to compose calls: chains run left to right, so `1.one().zero()` is
`zero(one(1))`. Every argument, the receiver included, is evaluated once, left
to right, before the call. Self and mutual recursion use the C stack; see
[tail recursion](#tail-recursion) for a guaranteed loop.

### Bindings and var

```blorp
pure func identity(value: Int) -> Int:
    value
pure func preserve() -> Int:
    original = 1
    var current = original
    current = identity(42)
    original
func main() -> Int:
    preserve()
```

This is [`binding/basic.brp`](test/test_compile/fixtures/binding/basic.brp); it exits 1.
`name = value` declares an immutable binding or reassigns an existing `var`,
and is rejected for an existing immutable binding. `var name = value`
declares a mutable one. `name: Type = value` always declares a new binding
and gives the initializer its expected type. An initializer may stand alone on
the next line, indented one level. Assignment copies, so reassigning a binding
never changes a value another binding holds.

There is no shadowing. A new parameter, local or pattern capture cannot reuse
a visible function, constructor or module alias, or an enclosing binding
("`helper` is already a function in this module"). An initializer sees the
scope before its binding, so `var current = value` copies a parameter into a
mutable local. Every initializer runs once, in source order, even when its
binding is unused.

A module constant has an explicit annotation, as in `LIMIT: Int = 7`. Its
initializer is closed: a scalar or `void` literal (including a negative
number), a constructor, record, List or tuple of closed values, or a named
function. Calls, operators, other constants, lambdas and control expressions
are rejected; name a callback as a function instead. Each read builds an
ordinary value, with no global storage. A callable constant can be called;
constants obey privacy, cannot be shadowed and take no part in UFCS.

### Numbers and operators

`Int` is a signed 64-bit integer. Literals are decimal, from
`-9223372036854775808` to `9223372036854775807`; a minus written directly
before a literal folds into it. Leading zeros and a prefix `+` are rejected.
`Float` is IEEE binary64. A Float literal needs a fraction with digits on both
sides of the point, an exponent, or both: `6.5`, `1e2`, `2.5e-3`, `-0.0`.
`.5`, `1.`, hexadecimal and digit separators are rejected, and a literal must
round to a finite value. Nothing converts implicitly: `1 + 2.0` is a type
mismatch.

Operators, from lowest to highest precedence:

| Level | Operators | Notes |
| --- | --- | --- |
| Comparison | `==` `!=` `<` `>` `<=` `>=` | Do not chain: `a < b < c` is an error. |
| Range | `..` | Only as a `for` iterable. |
| Additive | `+` `-` | Left-associative. |
| Multiplicative | `*` `/` `%` | Left-associative. |
| Prefix | `-` | Below postfix: `-x.abs()` is `-(x.abs())`. |
| Postfix | `.f()`, `.field`, `[index]` | |

Every operator calls a trait member (see [operators](#operators)). Spacing
never matters: `a-1` and `a - 1` are one subtraction. `-2.abs()` is rejected
with help to write `(-2).abs()` or `-(2.abs())`. `+=` and the other compound
assignments, `**` and `//` are rejected with a teaching message, as are `=<`,
`<>` and `=>` outside a Dict.

Arithmetic never fails at run time. Int `+`, `-`, `*` and negation wrap at the
64-bit limits; `/` truncates toward zero and `%` takes the dividend's sign;
division or remainder by zero gives 0. `INT_MIN / -1` is `INT_MIN` and
`INT_MIN % -1` is 0. When a wrapped result would be wrong, call `int`'s
`add_checked`, `subtract_checked`, `multiply_checked`, `divide_checked`,
`remainder_checked` or `negate_checked`, which return `Result[Int, MathError]`
(see the [checked fixture](test/test_compile/fixtures/arithmetic/checked.brp)). Naming
`MathError` or its cases `Overflow` and `DivisionByZero` needs
`_base: MathError(DivisionByZero, Overflow)`; `int: INT_MIN, INT_MAX` imports
the limits.

Float division and remainder by zero give `0.0`; other arithmetic follows
IEEE, including infinities and NaN. Every ordering comparison with NaN is
false, and NaN is unequal to itself. `float` also has `abs`, `copysign`,
`is_nan` and `is_finite`. `to_string` spells non-finite values `nan`, `inf` and
`-inf`, keeps `-0`, and uses the first precision from 6 to 17 significant
digits that round-trips: `(6.5 * 2.0).to_string()` is `13` and `0.1 + 0.2`
prints as `0.30000000000000004`.

`UInt8` is an unsigned byte, 0 to 255, declared by the base and available
everywhere. Its operations wrap and never fail, like Int's:

- An integer literal takes its type from its context, so `x: UInt8 = 200`,
  `byte + 1`, `byte == 0`, `[137, 80]` as a `List[UInt8]` and `Some(200)` where
  an `Option[UInt8]` is expected all compile. A literal that nothing constrains
  is `Int`. A literal outside the type is an error at the literal: `x: UInt8 =
  300` says "300 does not fit in UInt8" and helps with "UInt8 holds 0 to 255",
  and so does `-1`.
- `+`, `-`, `*`, `/` and `%` wrap modulo 256, so `0 - 1` is `255` and
  `200 + 100` is `44`. Division or remainder by zero gives 0.
- There is no negation: `-byte` is an error that says to write `0 - byte`.
- Nothing converts implicitly. `byte + count`, with `count` an `Int`, is a type
  error whose help names `to_int()` and `to_uint8()`; for an `Int` local that
  came from a lone literal it also suggests declaring `var total: UInt8 = 0`.
- `byte.to_int()` always succeeds. `count.to_uint8()` is an `Option[UInt8]`,
  `None` outside 0 to 255, and `text.parse_uint8()` is `parse_int` followed by
  `to_uint8`. `byte.to_string()` and `"${byte}"` give decimal digits.
- `UInt8` is `Equatable`, `Orderable` (so `max` and `min` work), `Hashable` and
  has every arithmetic trait but `Negatable`. A `fixed record` may hold one.

A sequence of bytes is `Bytes`, in the [`bytes` module](standard_library/README.md#bytes).

`Bool` is a `fixed union` of `True` and `False`. There are no Boolean
operators: the `bool` module's ordinary functions `not`, `and` and `or` are
selected with `bool: not, and, or` (or `bool: Bool methods` for UFCS), and
they evaluate every argument. Use `match` or `if` to skip work.

`Void` has one value, `void`. It may be a parameter, result, field or payload
type, and it needs no storage or ownership.

### Strings

A `String` is an immutable sequence of valid UTF-8 bytes. `length` counts
bytes, so `"é".length()` is 2; text is never normalized. A quoted literal
stays on one line and accepts the escapes `\n`, `\r`, `\t`, `\0`, `\\`, `\"`,
`\'`, `\{`, `\}` and `\u{X}`, with one to six hex digits naming a Unicode
scalar. Raw control bytes, DEL, malformed UTF-8 and unknown escapes are
rejected. Embedded NUL bytes count toward length and are preserved.

```blorp
pure func describe(name: String, count: Int) -> String:
    "${name}: ${count}"
func main() -> Int:
    print(describe("apples", 3) + "!")
    text =
        |first line
        |${"pipes"} and | bars
    print(text)
    0
```

This prints `apples: 3!`, `first line` and `pipes and | bars`. A
`${expression}` hole holds one expression on one line, of any type that
implements [`Stringable`](#operators): the hole calls its `to_string`, except
that a String hole is used as it is. Any other type is an error
("interpolation hole has type Point, which does not implement Stringable").
Holes run once, in written order, and cannot contain
another interpolated String. Write `$\{` for a literal `${`. `+` concatenates
two Strings; joining a String to another type with `+` is a type error whose
help suggests interpolation.

A `|` that starts a line begins a pipe String: the text after each marker,
verbatim and without escapes, joined with LF. It continues while the next line
has the same indentation before its `|`. The text starts after the single
marker, so `||x` is the text `|x`. `raw` alone on a line before the marker
lines makes a raw block, in which `${` is text.

A literal allocates its String once, on its first evaluation, and every later
evaluation shares it. Single-quoted Char literals are lexed but rejected
("Char literals are not supported yet").

#### String operations

The `string` module works on byte offsets and never cuts a scalar:

- `slice(value, start, end) -> Option[String]` takes half-open byte offsets and
  returns `None` unless `0 <= start <= end <= length` and both ends are scalar
  boundaries: `slice("éx", 0, 2)` is `Some("é")`, `slice("éx", 1, 2)` is `None`.
- `starts_with(value, prefix) -> Bool` compares bytes; an empty prefix is
  `True`.
- `byte_at(value, index) -> Option[UInt8]` reads one byte (`byte_at("é", 1)` is
  `Some(169)`); an index out of range is `None`.
- `from_codepoint(value) -> Option[String]` encodes one scalar, NUL included;
  negative values, surrogates and values above U+10FFFF are `None`.
- `append_int(text, value) -> String` appends an Int's decimal digits.
- `parse_int(text) -> Option[Int]` accepts an optional ASCII sign and decimal
  digits, leading zeros included, and nothing else: no whitespace, NUL, suffix
  or out-of-range value.
- `parse_float(text) -> Option[Float]` accepts a sign, digits, an optional
  fraction and an optional signed exponent; whitespace, hex, `nan`, `inf` and
  overflow are `None`, and underflow keeps the sign of zero.

`equals` compares complete byte sequences, and `list: join` joins Strings with
a separator.

### Lists

```blorp
func main() -> Int:
    values = [1, 2, 3]
    more = values.append(4)
    empty: List[Int] = []
    nested = [[1, 2], [], [3]]
    values.length() + more.length() + empty.length() + nested.length()
```

This exits 10. Every element has one type, decided by the expected List type
or by the first element ("list elements must have one type: element 2 is
Float, element 1 is Int"). `[]` takes its element type from context: an
annotation, a return type, a reassigned `var`, a List parameter (including
`List[T]`, as in `append([], 7)`), a record or variant field, or a later
element of a list whose type is already known. Without one it is rejected
("cannot infer the element type of an empty list literal").

Lists have value semantics: `append`, `set` and `concat` return a new List and
leave every alias unchanged. When the List being updated is not shared, the
update reuses its storage, so an accumulator grows in place. `get` returns an
`Option`, and `set` with an invalid index returns the List unchanged. The
`list` module's other functions, including `map`, `filter`, `any`, `find`,
`sort_by` and `contains`, are in the
[standard library README](standard_library/README.md).

### Records

```blorp
record Entry { number: Int, text: String }
pure func make_entry(number: Int) -> Entry:
    { text = number.to_string(), number = number }
pure func retitle(entry: Entry) -> Entry:
    { entry | text = "seven" }
func main() -> Int:
    old = make_entry(42)
    fresh = old.retitle()
    old.text.length() + fresh.text.length() + fresh.number
```

This exits 49. A record type is nominal. A literal names every field exactly
once, in any order, and its fields are evaluated in written order. Its type
comes from context: an annotation, a return type, a parameter (including a
UFCS receiver), or a field of an enclosing literal. A new unannotated binding
supplies none, and field names never select a record type. Braces may span
lines. `{}` is an empty Dict, and there are no empty records.

`entry.text` reads a field; `entry.retitle()` is a UFCS call. There is no
field assignment. `{ base | field = value }` builds a new record of the base's
type with some fields replaced, leaving the base unchanged. The base runs
once, then the fields the update reads are projected, then the replacements
run in written order, then the record is built. An update needs at least one
replacement; `{ first : 7 }` reports a missing update bar.

`record Box[T] { value: T }` declares type parameters. A receiving `Box[T]`
annotation is enough context for `{ value = 7 }` to infer `Int`.

A record whose fields are all `Int`, `Float`, inline records or fixed unions is
stored inline, as a C struct passed by value; any other record is a
reference-counted heap object. `fixed record` promises inline storage and is
checked: every field is `Int`, `Float`, a `fixed record`, a `fixed union` or an
opaque type over one of these, and a fixed type takes no type parameters and
never contains itself. An ordinary record is not accepted as a fixed field
even when it happens to be inline.

Records may be recursive, as in `record Node { value: Int, next: Option[Node] }`.
Values never form cycles, so reference counting frees them. Releasing a
recursive value recurses through its structure, so a very long chain can
exhaust the C stack.

### Tuples

```blorp
pure func first(value: (Int, String, Bool)) -> Int:
    (number, _, _) = value
    number
func main() -> Int:
    pair: (Int, String) = (1, "one")
    first((pair[0], pair[1], True)) + pair[1].length()
```

This exits 4. A tuple has two to four elements of any types. `(value)` groups
an expression, and a trailing comma does not make a one-element tuple. An
element is read with an integer literal index; a computed or out-of-range
index is a compile error. `(a, _, c) = value` and `for (name, _) in pairs:`
destructure flat tuples into new immutable names; nested destructuring and
member annotations are not supported. Tuple patterns nest inside `match`, and
`match (left, right):` matches a tuple directly. `(Int, String) -> Int` is a
callable with two parameters, and `((Int, String)) -> Int` takes one tuple.
Tuples have no `==`, ordering or trait implementations.

### Unions

```blorp
union Shape:
    Circle(Int)
    Square(Int)
    Empty
pure func width(shape: Shape) -> Int:
    match shape:
        Circle(radius): radius * 2
        Square(side): side
        Empty: 0
func main() -> Int:
    width(Circle(3)) + width(Square(4)) + width(Empty)
```

This exits 10. A variant is bare or has ordered fields, as in
`Pair(String, String)`; `Unit(Void)` has one field, written `Unit(void)`, and
`Variant()` is invalid. A bare constructor needs an expected union type from a
parameter, return type, annotation or reassignment: an unannotated `x = Empty`
reports "constructor needs an expected union type", and `match Empty:` is
rejected too.

A variant can also be written through its union, `Shape.Empty` and
`Shape.Circle(3)`, in values and in patterns. The name picks the variant, so
`x = Shape.Empty` needs no annotation, and it works whether or not the variant
itself was imported, so long as the union is visible. A generic union still
takes its type arguments from the expected type (`x: Option[Int] = Option.None`).
Both names are capitalized and the dot follows the union on the same line:
`Shape.Empty.Circle` and `read.Shape.Empty` (a module alias before a union)
are not forms. Write `read.Empty` for a variant through a module alias. A
pattern's union must be the matched value's: matching a `Shape` with
`Other.Empty` reports that `Other.Empty` is a variant of `Other`.

Variant names share one namespace with the module's functions and are unique
across its unions; a user module cannot declare a prelude constructor ("True
is provided by the prelude"). Types have a separate namespace, so a function
may share a type's name; a type name is unique and cannot replace a base type.

`union Result[T, E]:` declares type parameters, and an application such as
`Result[Box[Int], Int]` supplies all of them in order. A union of bare
variants compiles to a C enum. Any other union is a tagged C struct stored
inline that owns only its active variant's payload.

A non-generic union may hold itself as one direct payload of a variant, at
most one per variant, as in `Succ(Nat)`; that union is boxed, and releasing a
long chain is iterative. `Node(Tree, Tree)` or a generic `Next(Box[T])` reports
"recursive aggregate types are not supported yet". It
may also be recursive through records and Lists, as `Form` is through
`Call(String, List[Expr])` in the
[tree fixture](test/test_compile/fixtures/recursive/tree.brp). The rule is that values
stored by value form no cycle: a union stores its payloads by value, while a
record field, a List element and a union's one direct self payload are
references a cycle may pass through. A cycle through unions alone (`A(B)` and
`B(A)`, or `Node(Option[Node])`) and a generic declaration that applies itself
to its own parameter (`Tree[T]: Node(List[Tree[T]])`) are rejected at the type
that closes the cycle.

`fixed union` is a union with the `fixed record` rules; its payloads may also
be `Void`. `Bool` is declared this way.

### Opaque and private types

```blorp
opaque type UserId = Int
pure func user_id(value: Int) -> UserId:
    into_opaque UserId(value)
pure func number(id: UserId) -> Int:
    from_opaque UserId(id)
func main() -> Int:
    number(user_id(7))
```

An opaque type is distinct from its underlying type during checking and has
its layout at run time, with no wrapper. Only its declaring module may use
`into_opaque` and `from_opaque`; other modules use the functions it exports,
as in the [two-file example](test/test_compile/fixtures/opaque/int/main.brp). Opaque
types may have type parameters, including phantom ones the underlying type
does not mention (`id: Id[User] = into_opaque Id(7)`). Conversions take no
written type arguments. An opaque type inherits no fields or methods, and one
whose representation reaches itself is rejected.

A `resource type` is a nongeneric opaque type with a resource-free underlying
type. Its module alone may wrap and project values, using the same conversions.
Resources may be whole impure function or callable parameters and arguments;
they cannot be local aliases, results, constants, aggregate children, opaque
representations or explicit or inferred generic arguments.

```blorp
resource type Reader = Int

func consume(reader: Reader) -> Void:
    void

func invoke(body: scoped () -> Void) -> Void:
    body()

func during_read(reader: Reader) -> Void:
    read_more = func() -> Void: consume(reader)
    invoke(read_more)
```

`scoped` belongs after a declared parameter's colon, before its callable type.
It promises that the callable is used only during the call: it may be invoked
or forwarded to another scoped parameter. A closure capturing a resource or a
scoped callable is itself scoped; immutable local aliases preserve that fact.
Scoped callables cannot be returned, stored in aggregates or mutable bindings,
or passed to ordinary parameters. Pure functions and pure closures cannot receive
or capture resources. These are synchronous loan restrictions, with no new
runtime wrapper or automatic cleanup. The resource's owner must lend a valid
value and close it correctly.

The promise is on the declared parameter, not the general callable type.
Saving `invoke` as an ordinary function value loses that promise, so an indirect
call cannot pass a scoped closure. Trait requirements cannot declare scoped
parameters. `private resource type` keeps the declaration inside its module.

`private` before a declaration keeps it inside its module: it cannot be
imported or reached through an alias. A public function, field or payload
cannot mention a private type, even inside a type argument; bodies may.

### Pattern matching

```blorp
union Pair:
    Left(Int, Int)
    Right(Int, Int)
pure func pick(pair: Pair) -> Int:
    match pair:
        Left(item, _) | Right(_, item): item
pure func describe(values: List[String]) -> Int:
    match values:
        []: 0
        ["one"]: 1
        [_, ...rest]: 10 + rest.length()
func main() -> Int:
    pick(Right(1, 2)) + describe(["a", "b", "c"])
```

This exits 14. A scrutinee is a union, a List, a String, an Int or a tuple.
Patterns nest:

- `Number(value)` selects a constructor and binds its fields; `_` discards a
  field or, as a whole pattern, matches anything.
- A bare name in pattern position must be a visible constructor of the matched
  union. It never binds the whole value, so bind the scrutinee first when an
  arm needs it. `Empty` and `Empty()` are the same.
- `A(x) | B(x)` alternatives share one body and bind the same names at the
  same types.
- `[a, b]` matches an exact length; `[first, ...rest]` matches a prefix and
  binds a new List of the rest, and `..._` discards it.
- A String literal matches the complete byte sequence, and an Int literal
  such as `0` or `-1` matches that value, at the top of a match or inside
  `Exited(0)`, `(0, _)` or `[0, ...rest]`. A `-` before the digits is part of
  the literal, as in an expression, so `-9223372036854775808` is a pattern. A
  Float literal is not a pattern, because NaN never equals itself: bind the
  value and compare it in the arm.
- `alias.Variant` names a constructor through a module alias, and
  `Union.Variant` names it through its union; the union must be the matched
  value's.

Arms must be exhaustive and each must be reachable. Literals never cover every
String or Int, so a String or Int that literals test needs a catch-all, and a
repeated literal makes its arm unreachable. The scrutinee runs once and only
the first matching arm runs, and captures are immutable and local to their
arm. An arm is `Pattern: value`, one statement on the same line
(`None: failure = Some(error)`), or an indented block ending in a value; an
arm that must produce a value and ends in a statement reports "match arm has
no final value".

A function's last `match` is its result, and every arm is checked against the
return type. A `match` elsewhere, bound to a name or written as a statement,
is a join: the function continues with the selected arm's value, and an arm's
assignments to an enclosing `var` are visible afterwards. The first arm
decides a bound match's type unless an expected type is known; a statement
match is `Void`. Bind a `match` or `if` before using it inside a larger
expression such as a call argument.

### If, loops and tail recursion

```blorp
func main() -> Int:
    var total = 0
    for item in [1, 2, 3, 4]:
        if item == 2:
            continue
        else if item == 4:
            break
        total = total + item
    var countdown = 3
    while countdown > 0:
        countdown = countdown - 1
    sign = if total > 0:
        1
    else:
        0
    total * 10 + sign + countdown
```

This exits 41. `if` is an expression wherever a whole value goes: a result, an
initializer, a condition or a branch value. Its condition is a `Bool` and runs
once, and only the selected branch runs. With an expected type both branches
are checked against it; otherwise the first branch decides the type. Without
`else`, an `if` is `Void`. An `if` ends at its last block's dedent, so nothing
on the next line continues it.

`while condition:` and `for item in iterable:` are statements. `for` walks a
List or an ascending, end-exclusive Int range `low..high`; the iterable or
both bounds are evaluated once, low first, and an empty or reversed range runs
nothing. Each iteration binds a fresh immutable item (or `_`). `break` and
`continue` act on the nearest loop and stand alone on their line; they cannot
appear in an `if` or `match` used as a value, or in a lambda outside its own
loop. A loop's assignments to an enclosing `var` are visible after it.

#### Tail recursion

`@tail_recursive`, on the line before a function or before `pure func` or
`func` on the same line, guarantees that direct self calls in tail position
run as a loop with constant C stack:

```blorp
@tail_recursive
pure func count(remaining: Int, total: Int) -> Int:
    match remaining == 0:
        True: total
        False: count(remaining - 1, total + 1)
func main() -> Int:
    count(1000000, 0) % 256
```

This exits 64. Every self call is the whole final expression of the function
or of an arm of its final `match`; a final UFCS self call counts. Arguments,
receivers, initializers and scrutinees are not tail positions, and a self call
in a nested match or an `if` branch is rejected. The function is nongeneric,
contains a self call, takes no callable parameters, and has only unmanaged
values (no String, List or counted record) in its signature and in everything
it evaluates, even an unused initializer. All next arguments are evaluated
before any parameter is replaced. Other calls, mutual recursion included, use
the ordinary stack, and the annotation does not prove termination. See the
[accumulator fixture](test/test_compile/fixtures/tail_recursion/accumulator.brp).

### Option, Result and propagation

`Option[A]` is `Some(A)` or `None`; `Result[Value, Error]` is `Ok(Value)` or
`Err(Error)`. Both are ordinary unions in `_base.brp`, and the prelude supplies
their types and constructors. The `option` and `result` modules' helpers,
such as `map`, `and_then` and `get_or`, are in the
[standard library README](standard_library/README.md).

```blorp
import:
    string: parse_int
pure func parse(text: String) -> Result[Int, String]:
    match parse_int(text):
        Some(number): Ok(number)
        None: Err("invalid integer: ${text}")
pure func sum(left: String, right: String) -> Result[Int, String]:
    first ?= parse(left)
    second: Int ?= parse(right)
    Ok(first + second)
func main() -> Int:
    match sum("40", "2"):
        Ok(value): value
        Err(_): 0
```

This exits 42. `name ?= expression` evaluates a `Result`, binds the `Ok`
payload, and returns the `Err` from the enclosing function before any later
statement runs. The function returns a `Result` with the same error type; the
success types may differ. An annotation names the success type, and
`_ ?= expression` discards it. `?=` is allowed only among a function body's
own top-level statements: not in an `if` or `match` block, a loop or a lambda,
and not with `var`. It does not apply to `Option` or in `@tail_recursive`
functions; match in place, or move the nested block into its own function.

### Lambdas and callable values

```blorp
pure func apply[T, U](value: T, callback: pure (T) -> U) -> U:
    callback(value)
record Operation { run: () -> Int }
pure func stored(value: Int) -> Operation:
    { run = func() -> Int: value }
pure func offset(value: Int, amount: Int) -> Int:
    apply(value, pure func(item: Int) -> Int: item + amount)
func main() -> Int:
    operation = stored(30)
    callback: () -> Int = operation.run
    callback() + offset(10, 2)
```

This exits 42. `pure (Int, String) -> Int` is a pure callable type and
`(Int, String) -> Int` an impure-capable one. Callables are ordinary values:
bindings, fields, List elements, results and type arguments. A callable value
is a function name, a module-qualified function, a lambda or another callable
binding. A pure callable may be used where an impure-capable one is expected,
not the reverse; a pure function may create an impure callable but not call
one.

`pure func(params) -> Type: body` and `func(params): body` are lambdas, with a
body of one expression on the same line or an indented block. Parameter types
come from annotations or the expected callable type; a block body needs a
result annotation or a known expected result. A lambda captures immutable
outer values by value and keeps them alive while it lives. It cannot capture a
`var`: copy the value into an immutable binding first. A lambda may mutate its
own locals, and its body starts a new context for purity, loops and `?=`.

Call a callable binding as `callback(value)`. `operation.run()` is a UFCS call,
not a call of the field, so read the field into a local first. A stored local
callable may be a UFCS receiver, as in `saved.use(17)`, but a callable
parameter or a function name may not: `formal.use(17)`, `value.formal()` and
`identity.use(17)` report "callbacks require direct-call syntax". A generic
function named as a value is instantiated at each use; one without enough type
evidence is rejected rather than becoming a runtime generic.

### Generics and declaration bounds

```blorp
pure func second[A, B](first: A, second_value: B) -> B:
    second_value
pure func larger[Value: Orderable](left: Value, right: Value) -> Value:
    if left < right:
        right
    else:
        left
func main() -> Int:
    second("x", 3) + larger(4, 9)
```

This exits 12. Type parameters start with a capital ASCII letter and contain
only letters and digits. A generic body is checked once with its parameters
rigid: a `T` cannot be returned as an Int literal or passed to an Int-only
function. Calls never write type arguments. They are inferred from the
arguments, then from a known expected result, and every parameter must be
determined ("cannot infer the type parameter from the argument"). Each set of
type arguments compiles to its own C function. A generic recursion that would
need unboundedly many instances, by nesting a parameter inside a type
application on each call, is rejected.

`[T: Orderable + Hashable]` bounds a parameter with traits joined by `+`. A
record, union or opaque type may bound its parameters too, and the bound is
part of the type: every use of the type meets it under the bounds in scope.
Nothing is implied, so each signature restates it:

```blorp
record Keyed[K: Hashable] { key: K }
pure func key_hash[K: Hashable](keyed: Keyed[K]) -> Int:
    keyed.key.hash()
func main() -> Int:
    key_hash({ key = 5 })
```

Without the bound on `key_hash`, checking reports "Keyed[K] requires K:
Hashable" at the `K` in `Keyed[K]`, with the help "add Hashable to K's
bounds". A concrete argument without an implementation is rejected the same
way, with help to implement the trait or use a type that implements it.

### Traits

A trait declares pure methods whose first parameter is `Self`. A signature
without a body is required; one with a body is a default.

```blorp
trait Describe:
    pure func code(value: Self) -> Int
    pure func doubled(value: Self) -> Int:
        value.code() * 2
record Point { x: Int, y: Int }
implements Describe for Point:
    pure func code(value: Self) -> Int:
        value.x + value.y
pure func total[T: Describe](value: T) -> Int:
    value.doubled()
func main() -> Int:
    point: Point = { x = 1, y = 2 }
    total(point)
```

This exits 6. An implementation defines every required method with the same
parameter, result and purity contract and may override defaults; one that
uses only defaults ends after its receiver, with no colon. A module may
implement a trait only if it declares the trait or the receiver type. Traits
have no type parameters, generic or impure methods, or callable parameters
at the top level.

A method name names a family across receivers: importing `int: equals` makes
`equals` available for every type with an implementation, not only Int. Two
traits that declare the same method name are different families and need an
alias to be used together. A method can be a function value when the expected
callable type determines `Self`: with `int: hash` imported,
`callback: pure (Int) -> Int = hash` is Int's `hash`, and with `int: to_string`
imported, `ratios.map(to_string)` converts a List of Float.

A generic receiver takes fresh parameters, as in
`implements Describe for Box[Element: Describe]`; partial, concrete or nested
receiver patterns are rejected, and bounds never choose between overlapping
implementations. Checking proves that trait calls instantiate finitely many
functions; when it cannot, it reports
`cannot prove finite generic trait instantiation`.

#### Supertraits

```blorp
trait Ordered: Equatable:
    pure func before(left: Self, right: Self) -> Bool
trait Ring: Addable + Multipliable
record Version { major: Int, minor: Int }
implements Ordered for Version:
    pure func before(left: Self, right: Self) -> Bool:
        left.major < right.major
implements Ring for Int
pure func same[T: Ordered](left: T, right: T) -> Bool:
    left == right
```

Supertraits follow the trait's colon, joined by `+`, and its methods follow a
second colon. A trait with supertraits and no methods is a bundle, whose
implementations have no body. A bound provides every trait above it, so
`[T: Ordered]` allows `==`; the reverse does not hold. Implementing a trait
requires an implementation, written or automatic, of each direct supertrait
for the same receiver. A supertrait cycle and a public trait with a private
supertrait are rejected.

#### Operators

Each operator calls one member of a trait that the prelude selects; a user
trait or function with the same spelling cannot redirect it.

| Syntax | Trait member |
| --- | --- |
| `a == b`, `a != b` | `Equatable.equals`, `Equatable.not_equals` |
| `a < b`, `a > b` | `Orderable.less_than`, `Orderable.greater_than` |
| `a <= b`, `a >= b` | `Orderable.less_than_or_equal`, `Orderable.greater_than_or_equal` |
| `a + b`, `a - b` | `Addable.add`, `Subtractable.subtract` |
| `a * b`, `a / b`, `a % b` | `Multipliable.multiply`, `Divisible.divide`, `Modulable.remainder` |
| `-a` | `Negatable.negate` |
| `"${a}"` | `Stringable.to_string`, except for a String |

Both operands have the same type `Self` and are evaluated once, left then
right; an arithmetic result is `Self`. No operator is rewritten into another:
`!=` calls `not_equals`, `>=` is never a negated `<`, and `a - b` is never
`a + -b`. Int and Float implement all of these traits, String implements
`Equatable` and `Addable`, and List implements `Equatable`. A type without an
implementation reports, for example, "receiver does not implement Orderable".
`Stringable` means only that a value can be converted to a String, with no
rule about human or program text. Int, Float, String and Bool implement it,
and nothing derives it, so a record is interpolated once its author writes
the implementation.
`Orderable` requires `less_than` and defaults the other three; it is never
derived and does not provide `==`. A Bool result does not decide an operand's
type, so `[] == []` needs a typed binding.

#### Automatic equality

A record or union supports `==` when every field or payload does, with no
declaration. Fields compare in declaration order and stop at the first
difference; union tags must agree before payloads compare. A written
`Equatable` implementation replaces the automatic one for that type. A generic
type's condition comes from its actual fields, so a phantom parameter needs no
bound. An unused type with a field that is not Equatable is legal; using `==`
on it is rejected at that field. Tuples, opaque types and callables get no
automatic equality.

`Hashable: Equatable` requires `hash(value: Self) -> Int`, and equal values must
hash equally, so implementing it needs an `Equatable` implementation, written or
automatic. It is never derived; Int, String, Bool and List of Hashable implement it.

### Modules, imports and the prelude

```blorp
-- main.brp
import:
    ./helper: answer
func main() -> Int:
    answer()
```

```blorp
-- helper.brp
pure func answer() -> Int:
    42
```

This is [`import/basic`](test/test_compile/fixtures/import/basic/main.brp); it exits 42.
Each file is a module. An import block comes before the declarations, and each
row names one module:

- `./name` and `../name` are relative to the importing file, without `.brp`;
  a bare path such as `int` is a module under the library root. A path may
  pass through folders, as in `io/environment` or `./shared/names`, which name
  `io/environment.brp` under the library root or `shared/names.brp` beside the
  importing file. A module file beside a folder of the same name (`io.brp` and
  `io/`) is rejected at an import that passes through that name, such as `io`,
  `io/process` or `./io/process`, because the path would read as both a module and
  a folder. Other imports are unaffected.
- `module: answer, Shape(Circle, Square)` selects functions and types. A union
  selection lists the constructors it imports, and `Shape()` imports the type
  alone. A selected type also makes the module's functions on it available
  through UFCS.
- `module: Shape methods` makes the module's functions on `Shape` available
  through UFCS when `Shape` is already visible, without importing it.
- `module as alias` gives qualified access, as in `alias.answer()`,
  `alias.Circle(2)` and `alias.Shape`; it may precede `:` and selections.
- Selections may continue on an indented block of lines under `module:`.

A module offers only its own public declarations and never reexports what it
imports, so `int: Int` is rejected while `int: Int methods` works. Each module
is imported once per file, a selection appears once, and there are no
wildcards. Imported functions resolve names in their own module. Every
declaration has one identity, so same-named declarations in two modules are
distinct. Import cycles, including a module importing itself, are rejected at
the import that closes the cycle, and a module reached along several paths is
loaded once. Every loaded module is checked, including unused declarations.

Same-named functions that UFCS reaches on different receivers, such as List's
and Path's `join` once `path: Path` is selected, are told apart by the
receiver's type. Receivers may differ only in their type arguments, as
`List[String]` and `List[Int]` do, but two functions that one receiver type
could fit are rejected at the import that brings the second. A call needs
only the part of the receiver's type that tells them apart: in
`names.map(pure func(name: String): "${name}!").join(", ")` the receiver is
known to be a List before the lambda's result is, which chooses List's `join`.
When the known part still fits several, as a List whose element type is not
yet known fits both `List[String]` and `List[Int]`, the call reports
`method receiver needs an explicit type`; bind the receiver to a local with a
declared type.

The [prelude](standard_library/prelude.brp) is the only implicit import. User
modules receive its selections: the base types, `Bool`, `Option` and `Result`
with their constructors, the operator traits, `Equatable`, `Hashable`,
`Stringable`, `Dict`, the console functions `print` and `print_error`, the
generic `max` and `min` of any `Orderable`, the conversions
`to_uint8` and `parse_uint8`, and the methods of Int, UInt8, Float, String and
List, so `(42 + 1).to_string().length()`
needs no import. Other direct calls need named imports: console output is in
the prelude, while files, processes and the environment are explicit imports.
A user module cannot declare `print`, `print_error`, `max` or `min` ("max is
provided by the prelude", with the help "give this function another name").
Selecting `print` or `print_error` from `io/console` as well is redundant but
accepted: an import of a name already in scope enters once. A function whose
first parameter is a String and whose name is a String method the prelude
provides, such as `lines` or `parse_uint8`, is rejected as well, with "two
functions named lines can accept the same receiver"; give it another name. Library modules
receive nothing implicitly and cannot import user modules. Any module may
import the foundation module as `_base`.

### Dict

```blorp
import:
    dict as dict_ops
func main() -> Int:
    var scores: dict_ops.Dict[String, Int] = dict_ops.empty()
    scores = scores.set("alice", 95).set("bob", 80)
    scores = scores.remove("bob").set("bob", 81)
    none: Dict[String, Int] = {}
    literal = {"alice" => 95, "bob" => 80, "alice" => 99}
    scores.get_or("alice", 0) + literal.get_or("alice", 0) + none.length()
```

This exits 194. `Dict[K: Hashable, V]` is an insertion-ordered map from the
`dict` module; the prelude supplies the type and its methods, and `empty` and
`dict` come through an import. Int, String, Bool and Lists of keys are keys and
Float is not. A key type writes `Hashable` (and `Equatable` unless it is
automatic); `Hashable` requires `Equatable`, so nothing else is needed.

`{}` is an empty Dict whose types come from the expected type; without one it
is rejected with "an empty Dict needs its type". `{k => v, ...}` builds a Dict
in written order, each key before its value, so a repeated key keeps its first
position and its last value. `set` keeps an existing key's position, and
`keys`, `values` and `entries` list in insertion order. There is no `for` over
a Dict. The full contract is in the
[standard library README](standard_library/README.md#dict).

### Effects and I/O

The prelude's `print` writes a String and LF to stdout, and `print_error` writes
to stderr. Both are impure and write every byte, including NUL. `print_error`
writes the LF only after the text was written in full, and never retries.

#### Command-line input

`main(args: List[String])` receives the arguments, with the executable name at
index 0. `args.get(1)` is `Some(text)` or `None`, and `parse_int` and
`parse_float` convert text strictly. The
[addition](test/test_compile/fixtures/calculator/addition.brp),
[integer](test/test_compile/fixtures/calculator/integer.brp) and
[Float](test/test_compile/fixtures/calculator/float.brp) calculators print a result, or
print `missing input`, `unknown operation`, `invalid integer` or
`invalid float` and exit 1. They check the operation first, then each operand
in order, and ignore extra arguments.

#### Current directory

`io/environment: get_current_directory` is the impure
`get_current_directory() -> Result[Path, CurrentDirectoryError]`. Success is a
`Path`: a nonempty absolute UTF-8 spelling. Failure is `NotFound`,
`PermissionDenied`, `InvalidUtf8`, `Unreachable` (Linux's working directory
outside the process's root) or `OtherOs(errno)`; match on the variant, and
`"${error}"` reads as text. It prints nothing. See the
[complete program](test/test_compile/fixtures/current_directory/basic.brp).

#### Paths and the fs library

A `Path` is a nonempty UTF-8 spelling with no NUL byte. `"a/b".to_path()` is the
only way to make one and returns `Result[Path, PathError]`, so an empty or NUL
string is refused at the one place a path is made. Operations take a `Path`, so
swapped arguments no longer type-check. Notes:

- `join(base, child)` puts the child under the base, even when it is absolute
  (`/a` and `/b` give `/a/b`), and cleans nothing. It is not the join of Rust or
  Python, where an absolute child replaces the base; ask `is_absolute` first for
  that.
- `+` concatenates the two spellings as String `+` does, `a + b` is `ab`, never
  `a/b`.
- Equality is byte-wise on the spelling, so `a//b` differs from `a/b`, and the
  NFC and NFD spellings of one name are different paths.

Each file operation lives in its own module under `io/fs/` (`read`, `write`,
`entry`, `list`, `create_directory`, `remove_file`, `remove_directory`,
`remove_tree`, `rename`, `temporary_directory`), which also declares the error
union of its operations. A union holds only the failures its operations can
cause, carries no path, and is the error itself. `Union.Variant` names a
variant, so a caller matches exactly:

```blorp
import:
    io/fs/read: ReadError, read_text
    path: Path

func settings(path: Path) -> Result[String, ReadError]:
    result = path.read_text()
    match result:
        Err(ReadError.NotFound): Ok("")
        _: result
```

An error implements `Stringable` with fixed text: write `"${path}: ${error}"`
to read `settings.conf: no such file`. `json.ParseError` and the `io/process`
errors do the same; match on the variant, never on the text.

The library reads and atomically writes UTF-8 text files (`read_text`,
`write_text`) and binary files (`read_bytes`, `write_bytes`), inspects and
lists directories (`entry_kind`, `list_directory`), creates, removes and renames entries (`create_directory`, `create_directories`,
`remove_file`, `remove_directory`, `remove_directory_tree`, `rename`), folds
over a file's lines a block at a time (`fold_lines`), and scopes a temporary
directory to a callback (`with_temporary_directory`). The
[library README](standard_library/README.md#the-file-modules) owns every
operation's contract, edge cases and limits.

`io/process` runs a program and captures its output (`command`, `capture`,
`output`, `find_program`); `io/terminal` runs one on this terminal (`terminal_command`,
`run`, `exit_interrupted`). Their contract is in the
[standard library README](standard_library/README.md#process-execution).

### Tests

```blorp
import:
    test: TestSuite
private pure func adds() -> Bool:
    1 + 1 == 2
TESTS: TestSuite = {
    description = "arithmetic",
    tests = [("adds", adds)]
}
```

A test file declares a `TESTS: TestSuite` constant whose entries are named
callbacks returning `Bool`; a `TESTS` function, an imported `TESTS` and inline
lambdas are rejected. A lowercase `tests` constant is a naming error that
says to write `TESTS`. Compile one or more suite files into one program:

```sh
bin/blorp compile --test-suite blorp/test/test_common/test_utils/test_text.brp \
  [MORE_SUITES.brp ...] --library-root blorp/standard_library -o blorp/build/test_text.c
```

The generated entry runs each file's suite with `run_suite_result` in
command-line order and exits with `suites_exit_status`: 0 when no case failed,
otherwise 1. Callbacks may be pure or impure. They run in registration order
and continue after a failure, and an empty suite passes. A path may appear
only once, and a `private tests` constant is accepted only in the first file.

The component gate compiles each phase directory's suites into one program,
`all_suites`, under `blorp/build/self-hosted-tests/`, and runs it with strict
leak checking. The full run first fails on any `test_*.brp` under `blorp/test/`
that `COMPONENT_SOURCES` does not list. Each native e2e
case is a `Program` built with the constructors in
[`harness.brp`](test/driver/harness.brp): one compile,
against its `library_root` (the standard library unless the program names
another), within its allocation ceiling, then each run with its exact status, stdout,
stderr and strict allocation count. `INSTRUCTION_CHECK=on` also holds the
compile to its retired-instruction ceiling, read from macOS `/usr/bin/time -l`.

## The standard library

The explicit [`json` module](standard_library/README.md#json) parses and
renders pure JSON values, preserving exact numeric spelling and distinguishing
absent object names from null. Parse errors report UTF-8 byte offsets.

The library is ordinary Blorp under [`standard_library/`](standard_library/).
`_base.brp` declares the builtin types `Int`, `UInt8`, `Float`, `String`, `Void` and
`List`, the unions `Bool`, `Option`, `Result` and `MathError`, and the
`Equatable`, `Orderable`, `Hashable`, `Stringable` and arithmetic traits; only
it may declare builtin types. `prelude.brp` is the implicit import, and the operation modules
implement the traits and provide functions, some with `builtin("label")` bodies
that name a compiler-known operation. The
[standard library README](standard_library/README.md) owns every contract.

## Compiler architecture

[`src/main.brp`](src/main.brp) reads the command word and dispatches to
[`compile/compile_command.brp`](src/compile/compile_command.brp) or
[`format/format_command.brp`](src/format/format_command.brp). The compile
command loads the program, runs the pure pipeline
([`generate_c`](src/common/codegen/generate_c.brp)) and writes the C:

```text
lex -> parse -> load -> namespace -> check -> specialize -> lower -> own -> verify -> emit
```

Load drives lexing and parsing of each module, and checking begins by
building the namespace.

`src/` has `compile/` and `format/`, one folder per command (each holds its
`*_command.brp`: options, help text and shell), `common/`, and the entry
point `main.brp`. `common/` holds what the commands share, one folder per
layer. `utils/` holds helpers with no Blorp knowledge. `syntax/` is the front
end both tools share:
the lexer, the parser, and the token, source and name tables they build.
`analysis/` holds load, namespace and check (plus `assemble.brp` and
`ids.brp`). `codegen/` holds the phases after checking, specialize through
emit, plus `runtime` for the C fragments `emit` embeds, and `generate_c`, the
pipeline from a parsed program to C. `cli/` holds what the commands' command
lines share: exit statuses, usage errors and diagnostic reports. `format/` is
the formatter and the format command. Layers import only downward: `utils/`
imports itself; `syntax/` imports `utils/`; `analysis/` imports `syntax/` and
`utils/`; `codegen/` imports `analysis/`, `syntax/` and `utils/`; `cli/`
imports `syntax/` and `utils/`. A command folder imports itself and
`common/`, never another command or `main.brp`; `format/` imports only
`common/syntax/`, `common/cli/` and `common/utils/`, never `analysis/` or
`codegen/`. `main.brp` imports the commands and `common/cli/`. Inside
`analysis/` and `codegen/`, a folder imports only earlier folders; compiler
imports are relative paths, and bare paths name library modules. Only the
shell is impure: it reads modules with `fs.read_text`,
prints diagnostics and writes the output with `fs.write_text`. Everything in
between, diagnostic rendering included, is pure and reads no filesystem,
environment or clock. Each phase consumes its predecessor's sealed product and
returns a new one or its first error.

[`src/format`](src/format/format.brp) is not a phase: the
[formatter](#formatting) lexes and parses one file with the front end and
prints its tree, taking comments, blank lines and literal spellings from the
source between tokens. It imports only `common/syntax/`, `common/cli/` and `common/utils/`.

The output is replaced atomically, as by
[`write_text`](standard_library/README.md#the-file-modules): a symlinked output
keeps the link, the mode is preserved, a hard link keeps the old contents, and
a device or FIFO is refused. The output's directory must be writable. If the
final directory flush fails the compiler reports "could not write", although
the output may already be new.

### Phases

1. **Lex** ([`lex`](src/common/syntax/lex.brp)) turns one module's bytes into tokens with
   byte spans. It extends the shared name table, minting one `NameId` per
   identifier spelling; identifier tokens carry only that id, and reserved
   words and punctuation become keyword and symbol tokens, so later phases
   never compare spellings. Layout becomes NEWLINE, INDENT and DEDENT tokens.
2. **Parse** ([`parse`](src/common/syntax/parse.brp)) builds each module's syntax, each
   node with its span; direct and UFCS calls stay distinct. It recognises
   contextual words such as `fixed` by the ids the name seed gives them.
   [`assemble.brp`](src/common/analysis/assemble.brp) seals the modules and name table
   into an opaque `ParsedProgram`, issues declaration ids once (functions,
   records, unions and owner-qualified variants) and fixes the module
   dependency order, rejecting import cycles.
3. **Load** ([`load`](src/common/analysis/load/load.brp)) reads the root, `_base.brp`, the
   prelude and every imported module once per logically normalized path
   (symlinks are not resolved), lexes and parses each, and publishes the
   `ParsedProgram` with the source inventory diagnostics render from.
   `load_program_with_sources(root_path, library, sources)` accepts frozen
   `SourceFile` contents for file-backed modules, including unsaved files.
   Paths use the same working directory and lexical normalization as loading;
   duplicate normalized paths and NUL-containing caller paths reject through
   `SourceLoadFailure`; `DuplicateSourcePath` reports the normalized path.
   Supplied contents are authoritative, including invalid or empty text. They
   apply to every file-backed module, including a `--library-root` directory
   library's modules and its foundation and prelude files; embedded library
   modules retain their embedded contents. Normalization is lexical and
   case-sensitive, so `A.brp` and `a.brp` are distinct keys even on a
   case-insensitive filesystem. A row for a path outside the root's directory,
   or for a module nothing imports, is accepted and unused.
4. **Namespace** ([`namespace`](src/common/analysis/namespace/namespace.brp)), the first step
   of checking, gives each module one frozen scope in dependency order: its
   declarations, its imports and, for a user module, the prelude. A spelling
   denotes at most one entity per space: functions and constructors share the
   value space, types have their own, and an alias claims both.
   [`builtins.brp`](src/common/analysis/namespace/builtins.brp) validates the foundation and
   designates `Bool`, `Option` and `Result` by name and exact constructors.
5. **Check** ([`check`](src/common/analysis/check/check.brp)) validates every declaration,
   reachable or not, and publishes a `CheckedProgram` or a `CheckFailure`. It
   accepts declarations, constant annotations, signatures, traits and
   implementations, then constants and bodies, with expression-local
   inference. Every checked call carries its resolved target and complete
   substitution, every local read a function-owned `BindingId`, and every
   constructor its union and variant ids; matches are proved exhaustive.
   Operators become trait calls, Dict literals calls, and interpolation String
   concatenation. [`render.brp`](src/common/analysis/check/render.brp) turns a failure into
   diagnostics.
6. **Specialize** ([`specialize`](src/common/codegen/specialize/specialize.brp)) expands the
   call graph reachable from `main` into concrete instances, one per
   declaration and complete list of type arguments, phantom ones included. Its
   `SpecializedProgram` holds those functions and the record, union and List
   layouts they need, children before parents. No type parameter or trait
   reaches later phases. It also decides representation: unmanaged, a managed
   String, List or record root, a boxed union, or an inline union with owned
   children.
7. **Lower** ([`lower`](src/common/codegen/lower/lower.brp)) publishes ordered value
   definitions with function-owned `ValueId`s, separate from the bindings that
   name them. Matches become selection graphs over typed places that enter one
   shared body per arm; bound matches and `if` become joins with typed carried
   values, and loops carry values through their headers.
8. **Own** ([`own`](src/common/codegen/own/own.brp)) inserts reference counting: acquisitions,
   drops, borrows and transfers, each obligation named by an `OwnerId`. Every
   stored managed occurrence gets its own obligation, and an argument stays
   alive until the call's result owner exists. A managed parameter is owned
   when its value can reach an in-place update (`append`, `set`, `concat`,
   String `+`, `append_int`) or another owned parameter, and a call moves the
   caller's owner there at its last use. These labels change where a program
   copies, never what it computes. An obligation ends at its last use, where
   a move takes it or a drop ends it, except one that a loop iteration
   inherits but never reads, such as a field a `while` condition read: that
   one ends at the back edge. So an update (`append`, `set`, `concat`, `+`)
   reuses its operand when no later code can read the old value and no such
   owner still holds it; otherwise it copies. A record or tuple holding a
   String, List or record, and a lambda bound to a name, allocate each time
   they are built.
9. **Verify** ([`verify`](src/common/codegen/verify/verify.brp)) checks the ownership IR
   independently and alone produces a `VerifiedProgram`. It rejects dead or
   wrong owners, invalid borrows, undischarged obligations, calls that disagree
   with their callee's labels and malformed selection graphs, and checks the
   entrypoint conventions. It never repairs the IR. Its proof that no layouts
   form a by-value cycle also yields the aggregate order, every record and
   union after the layouts it stores by value, which the `VerifiedProgram`
   carries.
10. **Emit** ([`emit`](src/common/codegen/emit/emit.brp)) projects the verified program to C
   without repeating any check; retains and releases are exactly the explicit
   operations, and record and union definitions follow the verified aggregate
   order.

### C conventions

- Functions are `blorp_f_N`, one per instance. Each definition is preceded by
  a comment naming its source, `/* module.function */`,
  `/* module.function lambda */` or `/* equality for Type */`, so profiles read
  directly. Instances of a generic function share the label.
- `Int` is `int64_t`, with `INT64_C` literals and `INT64_MIN` for the minimum.
  `Void` is a zero `uint8_t`. A union of bare variants is a C enum; any other
  union is a struct of an enum tag and a C union of one field struct per
  variant with fields. Inline records are structs passed by value; managed
  records, Lists and Strings are counted heap objects.
- A String literal is a static byte array plus a
  `struct blorp_string_literal_site`, from which the runtime makes the shared
  String on first use.
- Floating-point contraction is off (`#pragma STDC FP_CONTRACT OFF` for Clang,
  GCC's `fp-contract=off` pragma), so each operation rounds separately.
- A wrapper calls the entrypoint as `int main(void)` or
  `int main(int argc,char **argv)` and exits through `blorp_program_finish`.
- Runtime helpers are emitted only when used, and the C has no indentation.

## Measuring

Generated C has two modes. By default (`-DBLORP_MEMORY_DIAGNOSTICS=0`)
allocation is plain `malloc` and `free`; with `-DBLORP_MEMORY_DIAGNOSTICS=1`,
as `make -C blorp test` builds the compiler, the runtime counts every
allocation and release.

### Leak check

```sh
bin/blorp compile program.brp --library-root blorp/standard_library -o program.c
clang -std=c11 -O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -fsanitize=address,undefined program.c -o program -lm -lpthread
BLORP_LEAK_CHECK=strict ./program
```

With `BLORP_LEAK_CHECK=strict`, a diagnostic build prints two lines to stderr
as it exits, `blorp: leak check: N allocs, N releases, N leaked, N bytes` and
then `blorp: peak heap: N bytes`, and exits with status 99 unless allocations
and releases balance and nothing is live. Any other value of
`BLORP_LEAK_CHECK` is an error. Two immortal objects are checked too: every
String literal must be back at its base reference count (else
`blorp: leak check: unbalanced string literals: N`), and the shared empty List
must have no owners left (else
`blorp: leak check: unbalanced empty list owners: N`). A diagnostic build
frees each literal at exit, so the report counts every used literal as one
allocation and one release.

The peak heap is the most bytes the program had requested and not yet
released at any one time, counted at each allocation and resize. It leaves out
the runtime's header and the allocator's rounding, which differ between
platforms and C libraries, so it depends only on what the program allocates
and repeats exactly from run to run. Plans set peak heap ceilings on it, not
on the process's peak memory footprint, which varies by a few percent between
runs.

### Allocation sites

```sh
clang -O0 -g -fno-omit-frame-pointer -DBLORP_MEMORY_DIAGNOSTICS=1 program.c -o program -lm -lpthread
BLORP_ALLOCATION_SITES=sites.txt BLORP_LEAK_CHECK=strict ./program ...
blorp/scripts/allocation-sites sites.txt program [program.c] [--top N]
```

With `BLORP_ALLOCATION_SITES=REPORT`, a diagnostic build records a 16-frame
`backtrace()` for every allocation and resize, keyed by stack, and writes the
table to `REPORT` at exit, with or without the leak check. Each line is
`count bytes resizes resized_bytes frame...`, most frequent first, with frames
innermost first as offsets from the executable's load base. An unwritable path
exits 1 at start. The variable needs `<execinfo.h>` and an image-base API
(macOS, and Linux with glibc) and is rejected elsewhere.

[`allocation-sites`](scripts/allocation-sites) (Python 3, with `atos` on
macOS or `addr2line` on Linux) symbolizes the report afterwards, since static
functions are not in the dynamic symbol table. It charges each stack to its
first `blorp_f_N` frame and prints the top sites by count, and by site and
immediate helper (the runtime function called, or `(direct)` for the
allocator). Given the C file it shows each site's `/* module.function */`
label. Recording stacks is slow, so use it for attribution, not timing. Keep
frame pointers, which macOS `backtrace()` follows; inlining merges helpers
into callers.

### Self-compile cost

```sh
blorp/scripts/self-compile-cost BASE CANDIDATE [--rounds N] [--optimize LEVEL] [--output DIR]
```

Compares two git revisions' cost compiling Blorp. It builds each from the
pinned seed in a detached worktree (normal and `-DBLORP_MEMORY_DIAGNOSTICS=1`
binaries at `--optimize`, default `-O2`), waiting while another session's
compiler, fixpoint or test driver is running. For two workloads, the base's
source compiled by both compilers (so only the compiler differs) and each
revision's own source, it prints strict-leak-check allocations (a leak fails
the run) and peak heap, and the median retired instructions of `--rounds`
(default 11) alternating runs from `/usr/bin/time -l` or `perf stat`. It also
says whether both compilers emit identical C for the fixed input. A compiler's
own runtime comes from the pinned seed, so the peak heap reads `missing`, with
a note, for a revision whose seed predates the peak heap line. Raw samples
stay under `--output`, by default
`blorp/build/self-compile-cost/<base>-<candidate>/`.

### Self-compile attribution

```sh
blorp/scripts/attribution/run [--output DIRECTORY] [--stage STAGE]... [--top N]
```

[`attribution/run`](scripts/attribution/run) measures the compiler compiling
itself (macOS and Apple Clang; several minutes). It reports List and String
update copies by Blorp function and C statement, atomic reference-count
operations by kind and source, allocations by kind and site, a `sample`
profile of an `-O2` self-compile, and the cycles that plain counts save over
atomic ones. Its stages are `build`, `markers`, `copies`, `rc`, `allocations`,
`profile`, `timing` and `report`, which `--help` describes. Raw data and the
markdown tables go to the ignored `build/attribution/`.

The `markers` stage builds a compiler from a scratch copy of `src` whose
`emit.brp` is patched to mark each reference-count operation with its source;
the `copies` and `rc` stages rewrite the generated C. Their patchers anchor on
exact lines of `emit.brp` and on the runtime helpers' C shapes, so an edit to
either can break them, and no gate runs them. A patcher that no longer fits
stops its stage and names the anchor or pattern; update it in
[`patch_emit_markers.py`](scripts/attribution/patch_emit_markers.py) or the
instrumenter.

## Bootstrap

`make -C blorp` builds the compiler with a pinned seed: an earlier compiler,
published as a release. [`bootstrap.env`](bootstrap.env) names the release
tag, its source commit and a SHA-256 digest for each native target (macOS
ARM64, Linux x64 and Linux ARM64).
[`scripts/blorp-compiler-bootstrap`](../scripts/blorp-compiler-bootstrap)
downloads the seed for this machine, verifies the digest, caches it and runs
it on `blorp/src/main.brp` to produce `blorp/build/blorp.c`, which `make`
links. The compiler's own source can use only what the seed supports.

The embedded standard library is a generated module,
`blorp/build/generated/embedded_library.brp`, which `src/common/analysis/load/load.brp`
imports. The seed builds [`scripts/embed_library.brp`](scripts/embed_library.brp),
and `make -C blorp compiler` runs it whenever a library file, a library folder
or the generator changes. It embeds every `.brp` file under the library at any
depth, named by its path below the root, such as `io/fs/read.brp`. Anything that
compiles `src/main.brp` directly (a benchmark recipe, a seed workflow) must run
`make -C blorp build/generated/embedded_library.brp`
first. The generated file is not formatted, and the repository formatting
gate does not walk `blorp/build`; format the files you changed rather than
running `blorp format blorp`. The gate's roots are `blorp/scripts`, `blorp/src`,
`blorp/standard_library` and `blorp/test`.

`scripts/blorp-fixpoint --prove` checks that the compiler reproduces itself:
the seed builds A, A builds B and B builds C. B and C must emit identical C, A
and B must agree on every fixture, and B must pass the components and the e2e
selection. Artifacts stay under `blorp/build/fixpoint/`.

A seed rotation moves the pin forward. Once the seed workflow has published
and qualified a release for every target, one change updates the tag, source
commit and all three digests in `bootstrap.env` together, after
`make -C blorp test`, the fixpoint and `bash blorp/test/test_bootstrap/test_bootstrap.sh`
pass against the new pin. [scripts/README.md](../scripts/README.md#rotating-the-seed-pin)
describes the resolver, its cache and the rotation in full.
