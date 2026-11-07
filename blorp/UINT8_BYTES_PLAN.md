# UInt8 and Bytes

Plan revision 2, 2026-11-06, against origin/main `dd9ef71cf`. Revision 1's review
(2 blockers, 8 should-fix) is folded in. Keith set the direction: a `UInt8`
numeric type, which Blorp "would add eventually anyway", and
`opaque type Bytes = List[UInt8]`, with no separate `Byte` type. Keith approved
U2 to U9 and B1 to B3 as recommended on 2026-11-06, and started S0, which
decides U1 by measurement.

## Problem

A Blorp `String` must be valid UTF-8, so data that is not text has no
representation:

- `fs.read_text` fails with `InvalidUtf8` on a binary file, and nothing else
  reads or writes one;
- a directory entry whose name is not UTF-8 fails the whole listing (D8 in
  `FILESYSTEM_DECISIONS.md`), and a `Path` type (D13) waits on bytes;
- the process API captures text only (its decision P1);
- hashing, encodings and binary formats have nothing to work on.

`List[Int]` is the only stand-in. It costs 8 bytes per byte, and nothing
keeps its values in 0 to 255.

## Background

How Int and Float are built in today:

- **Declaration.** `standard_library/_base.brp:5-9` declares
  `type Int = builtin` and `type Float = builtin`. Their behaviour is library
  code in `int.brp` and `float.brp`, over `builtin("int.add")`-style labels.
- **Compiler tables.**
  - `namespace/builtins.brp` has the type roles at `:332-338` and the
    `PrimitiveType` and `RuntimeType` tables at `:101-112`.
  - The parser has a name-to-role table (`parse.brp:3806-3851`).
  - `_base` must declare every role, or compilation stops with
    `MissingBuiltinType` (`builtins.brp:450-457`).
  - `TypeRef` is declared twice, once for check (`check/model.brp:101`) and
    once for specialize and later phases (`specialize/specialize.brp:170`).
    67 lines in `blorp/src` name `IntType` or `FloatType`, about 25 of them in
    exhaustive matches.
- **Operators.** `+`, `==`, `<` and the rest are trait calls
  (`check/expressions.brp:702-713`). `int.brp` implements those traits with
  nine `RuntimeOperation`s:
  - `IntAdd`, `IntSubtract`, `IntMultiply`, `IntDivide`, `IntRemainder`;
  - `IntToString`;
  - `IntEquals(Bool)`, `IntLessThan(Bool)`.

  Each runs through `builtins.brp`, the parser's label table, specialize and
  emit, with C helpers at `emit.brp:2386-2396`. Int wraps on overflow, and
  division and remainder by zero give 0.
- **Literals.** An integer literal always gets the type `Int`
  (`check/expressions.brp:587`), and the parser checks its range against Int64
  (`parse.brp:821-851`).
  - A closed expected type does reach List literal elements
    (`constructors.brp:673-690`).
  - An operator's operands are entered against an unsolved `Self` variable, so
    in `0 - x`, `255 == byte` or `Some(200)` the literal is typed `Int` before
    anything says otherwise.
- **Opaque types and traits.** Opaque types implement traits by hand, with
  precedent in `lower.brp:51` and `own.brp:51`. Neither equality nor `Hashable`
  is derived for them (README "Automatic equality").
- **List storage** is per element C type (`runtime/list.brp:271`, with keys at
  `:42-51`), so a `List[UInt8]` packs `uint8_t` once `UInt8` has a key.
- **Natives** take `Int`, `String` or `List[String]` parameters, and return
  `Int`, `String`, `List[String]` or `Void` (`builtins.brp:192-203`).
  `emit.brp:1275` hard-codes the String list.
- **Fixtures.** Test fixtures may bring their own `_base` that declares
  built-in types (`test/e2e/trait_inputs/*/library/_base.brp`). New compiler
  support can therefore be tested before the production library uses it.
- **Bootstrap.** The pinned seed parses `_base` and every library module the
  compiler imports: `bool`, `int`, `option`, `result`, `list`, `string`,
  `float`, `dict`, `fs`, `io`, `system` and `path`. None of them can name
  `UInt8` until the seed knows it.

## Decisions for Keith

- **U1, the integer model.** The width family should be one concept, because
  Keith expects more widths. Two shapes are possible. *Recommended:* let the
  spike (S0) choose between them by measurement.
  - **(a) A payload.** `fixed union IntegerFormat: Int64Format, UInt8Format`,
    and `TypeRef`'s `IntType` becomes `IntegerType(IntegerFormat)`. A new
    width adds one variant. The risk is that equality, hashing and the many
    `== IntType` checks now compare a payload, and that construction may
    allocate.
  - **(b) Bare variants plus a projection.** Keep a bare variant per format
    (`IntType`, `UInt8Type`) and add one function,
    `integer_format(TypeRef) -> Option[IntegerFormat]`, which shared sites
    call for limits, C type and wrapping. A new width adds one `TypeRef`
    variant and touches the exhaustive matches again, but costs nothing at
    run time.

  Either way, one function owns each format's minimum, maximum, C type and
  wrapping rule, and check and verify both call it, so a `UInt8` value of 300
  cannot slip through one phase. Under (a), the existing
  `BuiltinTypeRole.IntegerType` is renamed so that two concepts do not share
  a name.
- **U2, literals.** *Recommended:* an integer literal whose type is not yet
  known gets a deferred integer type, as Rust's `{integer}` does:
  - it unifies with any integer format;
  - it defaults to `Int` when nothing constrains it;
  - its range is checked when the type is fixed.

  So all of these compile:

  ```blorp
  x: UInt8 = 200
  byte + 1
  0 - byte
  byte == 0
  Some(200)    -- where an Option[UInt8] is expected
  ```

  `x: UInt8 = 300` is an error at the literal, "300 does not fit in UInt8",
  with help "UInt8 holds 0 to 255", and so is `-1`. A literal that nothing
  constrains is `Int`, so every existing program keeps its types. The same
  rule types an Int literal pattern against a `UInt8` place.

  This is a new inference kind, not a one-line hook. S0 measures it.
  Alternative: type literals only from a closed expectation. Then `0 - x`,
  `1 + byte` and `byte == 0` would each need an annotation, which is the
  wrong default for "easy to learn".
- **U3, arithmetic.**
  - *Recommended:* `+`, `-`, `*`, `/` and `%` wrap modulo 256, as Int wraps,
    so `0 - 1` is `255`.
  - Division and remainder by zero give 0.
  - No `Negatable`: an unsigned value has no negation. `-byte` reports
    "UInt8 has no negation", with help "write 0 - value for the wrapping
    result". That needs a type-specific render case, since a missing trait
    gives a generic message today.
  - No `_checked` forms until a consumer needs them.
- **U4, mixing.** *Recommended:* no implicit conversion. `byte + count`, with
  `count` an `Int`, is a type error whose help names `to_int()` and
  `to_uint8()`. With U2, literals never need converting. An unannotated
  `var total = 0` is `Int`, so the help for `total + byte` also suggests the
  annotation `var total: UInt8 = 0`.
- **U5, conversions.** *Recommended:*
  - `value.to_int() -> Int` always succeeds;
  - `count.to_uint8() -> Option[UInt8]` is `None` outside 0 to 255;
  - `value.to_string()` prints decimal digits;
  - `text.parse_uint8() -> Option[UInt8]` is `parse_int` followed by
    `to_uint8`, written in Blorp, with the same strictness as `parse_int`;
  - no wrapping or truncating conversion until a consumer needs one.
- **U6, traits.** *Recommended:* `Equatable`, `Orderable`, `Hashable`,
  `DictKey`, `Addable`, `Subtractable`, `Multipliable`, `Divisible` and
  `Modulable`. A fixed record may hold a `UInt8` field, which needs one arm in
  `declarations.brp:991` (`fixed_storage`).
- **U7, bit operations.** *Recommended:* not in this plan. Int has none
  today. A separate change gives every integer format the same bitwise
  operations and shifts, with names that do not collide with Bool's `and`,
  `or` and `not`. Until then, a big-endian 16-bit value is
  `high.to_int() * 256 + low.to_int()`.
- **U8, visibility.** *Recommended:* `_base` declares `UInt8`, and the
  prelude exports it with `uint8: UInt8 methods, Int methods`, since
  `to_uint8` has an Int receiver and lives in `uint8.brp`. It is a base type,
  not an import.
- **U9, `String.byte_at`.** It returns `Option[Int]` today, which would
  disagree with `Bytes.get`. *Recommended:* change it to `Option[UInt8]` in a
  final landing after the library exists. The compiler's lexer calls it, so
  that landing updates compiler source too, which the rotated seed allows.
- **B1, the `Bytes` surface,** in a new module `bytes.brp`. *Recommended:*

  ```blorp
  opaque type Bytes = List[UInt8]

  pure func from_list(values: List[UInt8]) -> Bytes
  pure func to_list(data: Bytes) -> List[UInt8]          -- erased: no copy
  pure func length(data: Bytes) -> Int
  pure func is_empty(data: Bytes) -> Bool
  pure func get(data: Bytes, index: Int) -> Option[UInt8]
  pure func get_or(data: Bytes, index: Int, fallback: UInt8) -> UInt8
  -- Clamps to the data, as List's take and drop do: never fails.
  pure func slice(data: Bytes, start: Int, end: Int) -> Bytes
  pure func starts_with(data: Bytes, prefix: Bytes) -> Bool
  pure func to_text(data: Bytes) -> Option[String]       -- None unless UTF-8
  pure func to_bytes(text: String) -> Bytes
  implements Equatable for Bytes
  implements Addable for Bytes                            -- concatenation
  implements Hashable for Bytes                           -- delegates to List's
  implements DictKey for Bytes
  ```

  `String.slice` returns `Option` only because it must not cut a UTF-8
  character, and bytes have no such boundary. `to_list` hands `map`, `filter`
  and `find` to the List library at no cost. `to_bytes` and `to_text` are
  natives: a byte-by-byte loop over `byte_at` would be slow and full of
  `Option`s.
- **B2, imports.** *Recommended:* `import: bytes: Bytes, from_list, String
  methods`.
  - Selecting `Bytes` gives its functions through UFCS.
  - `from_list` takes a List, so it is imported by name.
  - `String methods` reaches `text.to_bytes()`.

  A type is not a namespace, so revision 1's `Bytes.from_list(...)` was
  wrong. A module alias also works: `bytes as B`, then `B.from_list(...)`.
- **B3, file I/O,** in `fs.brp`. *Recommended:*
  - `read_bytes(path) -> Result[Bytes, IOError]`, which never fails on
    content, with `read_text`'s open and read rules;
  - `write_bytes(path, data: Bytes) -> Result[Void, IOError]`, atomic with
    `write_text`'s rules and error kinds.

  Binary process capture and `Path` (D13) follow in their own plans.

Two limits remain and are stated rather than fixed:

- A constant cannot call a function, so a `Bytes` constant such as a file
  signature is a function returning `from_list([137, 80, 78, 71, ...])`.
- `for byte in data` needs `data.to_list()`.

## Landings

1. **S0, a spike** that never lands. On a branch, measure:
   - (a) and (b) of U1, as before-and-after self-compile allocations and
     instructions for the `IntType` rename alone;
   - a prototype of the deferred integer literal (U2), with its cost and
     whether every existing fixture keeps its types.

   It reports the line counts that set the ceilings below, and decides U1.
2. **L0, the integer model.** The rename that U1 chose, with no behaviour
   change. The generated self C is byte-identical, and self-compile cost is
   measured against the base.
3. **L1, the compiler learns UInt8.** This landing adds:
   - the role, which stays optional until L3, so that today's `_base`, which
     cannot declare it before the rotation, still compiles;
   - the C type `uint8_t` and its List element key;
   - the nine operations and their wrapping C helpers;
   - the deferred integer literal (U2) and the literal-pattern `fits` rule;
   - the `UInt8ListRuntimeType`, parameter and payload kinds;
   - the natives `fs.read_bytes`, `fs.write_bytes`, `string.to_bytes` and
     `bytes.to_text`;
   - the messages for U2, U3 and U4.

   Tests use fixtures with their own `_base`, so nothing the seed parses uses
   `UInt8` yet.
4. **L2, seed rotation** onto L1. It also switches the seed family name, both
   in the pin and in `seed_release_family` (see the rename notes).
5. **L3, the library.** This landing adds:
   - `type UInt8 = builtin` in `_base`, which makes the role mandatory, and
     the prelude exports;
   - `uint8.brp`, with its traits, conversions and `parse_uint8`;
   - `bytes.brp`;
   - `read_bytes` and `write_bytes` in `fs.brp`;
   - README and grammar updates;
   - e2e examples covering literals, wrapping, conversions, mixing errors,
     Bytes, and binary file round trips including NUL and 0xFF, all under
     ASan and the strict leak check.
6. **L4, `byte_at`** (U9). Change its result to `Option[UInt8]` and update
   its callers, including the compiler's lexer.

## Ceilings

These are proposed now and re-set from S0's measurements before L0 begins.

| Landing | Production lines | Self-compile allocations and instructions | Fixed-input instructions |
| --- | --- | --- | --- |
| L0 | net 0 ±20 | measured, at most +0.1% | — |
| L1 | at most +700 compiler lines | at most +0.6% | at most +0.2% |
| L3 | library lines reported | at most +0.3% | — |
| L4 | compiler call sites only | at most +0.1% | — |

L0's self C must be byte-identical.

## Risks and unknowns

- **The deferred literal (U2) is the hard part.** It touches inference and
  must leave every existing program's types unchanged. The check is output
  identity across all 685 e2e fixtures, which the Int literal patterns change
  also used.
- **U1's cost.** Under (a), a payload in `TypeRef` may allocate or slow
  equality. S0 decides.
- **The optional role in L1** is a temporary state: the compiler accepts a
  `_base` without `UInt8` until L3. L3 removes it, and a test proves that a
  `_base` missing the role is then rejected.
- **Native payloads** need their List runtime emitted even when a program
  names no `List[UInt8]`, because `emit.brp:1275` hard-codes the String list
  today.
- **Other `TypeRef` matches.** Code outside `blorp/src` may match on
  `TypeRef`, such as the formatter that `FORMATTER_PLAN.md` begins. L0 must
  find it all.

## Testing

Each landing follows the repository rules:
- a failing test first;
- unit suites at each phase the landing touches, in active suites;
- e2e examples with exact output and allocation pins;
- rejections with exact message, help and span;
- one oracle per new rule, proved by breaking it;
- `make -C blorp test`, `scripts/blorp-fixpoint --prove`, and branch CI on
  all four jobs.

Each landing gets its own implementation brief.
