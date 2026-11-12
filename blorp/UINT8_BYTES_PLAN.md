# UInt8 and Bytes

Plan revision 3, 2026-11-08. Revision 2 was written against origin/main
`dd9ef71cf`, and revision 1's review (2 blockers, 8 should-fix) is folded in.

Keith set the direction: a `UInt8` numeric type, which Blorp "would add
eventually anyway", and `opaque type Bytes = List[UInt8]`, with no separate
`Byte` type. He then decided:
- **2026-11-06:** U2 to U9 and B1 to B3, approved as recommended;
- **2026-11-07:** U1 as (a), after the S0 spike, and the spike's ceilings.

**Status:** S0 and L0 implementation/local qualification are complete. Full
instruction-enabled tests, fixpoint, fixture parity, independent code/test
reviews and four-platform CI pass. L0 is published on origin/main. L1
started on 2026-11-11, when Keith asked for `Bytes` in the library. The corrected L0 line allowance is recorded under Ceilings;
performance caps are unchanged. Measured L0 costs, all within the caps:
fixed-input allocations +0 and instructions +0.014% (median of 3); own-source
allocations +0.21% and instructions +0.17%.

**Stale citations.** The `src/` layout split (`065e5e9ce`) and the
repository-wide formatting (`1ca080abd`) landed after revision 2:
- check, specialize, lower, own, verify, emit, namespace and runtime moved
  under `blorp/src/compile/`;
- the parser moved under `blorp/src/syntax/`.

So the `file:line` citations below are stale. Re-derive them from current
main before writing a brief.

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
  - `common/analysis/namespace/builtins.brp` has the type roles at `:332-338` and the
    `PrimitiveType` and `RuntimeType` tables at `:101-112`.
  - The parser has a name-to-role table (`parse.brp:3806-3851`).
  - `_base` must declare every role, or compilation stops with
    `MissingBuiltinType` (`builtins.brp:450-457`).
  - `TypeRef` is declared twice, once for check (`common/analysis/check/model.brp:101`) and
    once for specialize and later phases (`common/codegen/specialize/specialize.brp:170`).
    67 lines in `blorp/src` name `IntType` or `FloatType`, about 25 of them in
    exhaustive matches.
- **Operators.** `+`, `==`, `<` and the rest are trait calls
  (`common/analysis/check/expressions.brp:702-713`). `int.brp` implements those traits with
  nine `RuntimeOperation`s:
  - `IntAdd`, `IntSubtract`, `IntMultiply`, `IntDivide`, `IntRemainder`;
  - `IntToString`;
  - `IntEquals(Bool)`, `IntLessThan(Bool)`.

  Each runs through `builtins.brp`, the parser's label table, specialize and
  emit, with C helpers at `emit.brp:2386-2396`. Int wraps on overflow, and
  division and remainder by zero give 0.
- **Literals.** An integer literal always gets the type `Int`
  (`common/analysis/check/expressions.brp:587`), and the parser checks its range against Int64
  (`parse.brp:821-851`).
  - A closed expected type does reach List literal elements
    (`constructors.brp:673-690`).
  - An operator's operands are entered against an unsolved `Self` variable, so
    in `0 - x`, `255 == byte` or `Some(200)` the literal is typed `Int` before
    anything says otherwise.
- **Opaque types and traits.** Opaque types implement traits by hand, with
  precedent in `lower.brp:51` and `own.brp:51`. Neither equality nor `Hashable`
  is derived for them (README "Automatic equality").
- **List storage** is per element C type (`common/codegen/runtime/list.brp:271`, with keys at
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

- **U1, the integer model. Decided as (a)** on 2026-11-07, after S0. The width
  family should be one concept, because Keith expects more widths. The two
  shapes considered:
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
  `Addable`, `Subtractable`, `Multipliable`, `Divisible` and
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

  **Since revision 3,** the `Path` work gave the library `Path` and exact
  errors, and split `fs.brp` into `io/fs/` modules. So L3 adds
  `read_bytes(path: Path) -> Result[Bytes, ReadError]` to `io/fs/read` and
  `write_bytes(path: Path, data: Bytes) -> Result[Void, WriteError]` to
  `io/fs/write`, beside `read_text` and `write_text`; L1's natives take the
  path's text.

Two limits remain and are stated rather than fixed:

- A constant cannot call a function, so a `Bytes` constant such as a file
  signature is a function returning `from_list([137, 80, 78, 71, ...])`.
- `for byte in data` needs `data.to_list()`.

Follow-ups Keith raised on 2026-11-11, for after L3:
- **A `to_text` that does not copy.** `struct blorp_string` and a
  `List[UInt8]` share their header (references, length, capacity), and the
  String adds a trailing NUL that its capacity excludes. A uniquely owned
  list with a spare byte can become the String in place: validate, write the
  NUL, lower the capacity by one. The decision is made at run time, as
  copy-on-write appends are, so the native needs its operand consumed on its
  last use rather than a new static analysis. `read_bytes` and `read_exact`
  could allocate one spare byte so that the conversion never reallocates, and
  `to_bytes` works the same way in reverse. Measure allocations and copies on
  a read-then-decode workload before deciding.
- **Streaming decode.** `to_text` returns `Option`, so it cannot tell an
  invalid sequence from data that ends partway through a character, which a
  chunked decoder must carry into the next chunk. The first streaming
  consumer (live process output, chunked standard input) brings one
  primitive that returns the longest whole-character prefix and the 0 to 3
  carried bytes, and fails only on a sequence no later byte can fix. Today's
  APIs do not need it: `fold_lines` completes a character cut at its buffer
  end, `capture` validates once after the child is reaped, and the language
  server decodes whole message bodies.

## S0 results

The spike ran on 2026-11-07. Its report and branches stayed on the machine
that ran it, outside the repository, and none of them landed; this section
keeps what a later landing needs. What it found:

- **U1 (a) costs nothing.** Both `TypeRef`s are boxed unions already, so even
  a bare `IntType` is one counted node. Under (a), the format is a C enum
  stored inside that node, and the node does not grow.
  - Fixed-input allocations: +0.
  - Fixed-input instructions: +0.003%. Option (b) measured +0.05 to +0.06%.
  - Fixed-input self C: byte-identical.
  - All 685 e2e fixtures gave identical output.
  - Production lines: +114 −103 for (a), against +59 −14 for (b).
  - (a) won on design: a new width adds one `IntegerFormat` variant.
- **U2 works.** It is built like Rust's `{integer}`. An unconstrained literal
  becomes `Int` when the call, variant, record or list it fills finishes, when
  lambda resolution stops making progress, or when its type is published.
  - These check:
    - `x: UInt8 = 200`, `byte + 1`, `0 - byte` and `byte == 0`;
    - `Some(200)` against an `Option[UInt8]`, and `[137, 80]` against a
      `List[UInt8]`;
    - `byte.max(3)`, and a generic `larger(byte, 3)` in either argument
      order.
  - `x: UInt8 = 300` gives "300 does not fit in UInt8", with help "UInt8
    holds 0 to 255".
  - All 685 fixtures are identical, and existing messages are byte-identical.
  - The tuned version costs +0.10% fixed-input instructions and +420
    allocations, with about 225 lines of literal machinery. A first version built error values
    eagerly on two hot paths; allocation-site tracing found it.
  - One limit: in `g(h(5), byte)` the 5 defaults to `Int`, as it does today.
- **L1's estimated size, about 600 lines:**

  | Part | Lines |
  | --- | --- |
  | Role, word, parse, head and spelling | 25 |
  | Format arms | 10 |
  | Limits authority | 15 |
  | Deferred literal and range message | 225 |
  | Pattern `fits` rule and verify range check | 30 |
  | C type and List key | 20 |
  | Nine operations, labels, contracts, emit names, wrapping C helpers | 60 |
  | `UInt8ListRuntimeType`, parameter and payload kinds | 50 |
  | Four natives with their C runtime | 120 |
  | U3 and U4 messages | 45 |
- **Two spike shortcuts L1 must fix.**
  - Literal slots borrowed the expected variable's `TypeParameterId`. Give
    `InferenceSlot` an origin variant instead.
  - The spike wrote `IntegerType(_)` where the format matters. L0 routes every
    such site through an exhaustive format function.
- **One format-blind site no match will flag.** Emit writes every integer
  literal as `INT64_C(…)` from its `IntegerValue`, without looking at the
  format (`emit.brp`, `IntegerValue` in `lower.brp` and `own.brp`). C converts
  it to `uint8_t` silently, and only check's `integer_fits` guards the range.
  L1 makes the literal's emission follow its format.

## Landings

1. **S0, a spike** that never lands (done; see "S0 results"). On a branch, measure:
   - (a) and (b) of U1, as before-and-after self-compile allocations and
     instructions for the `IntType` rename alone;
   - a prototype of the deferred integer literal (U2), with its cost and
     whether every existing fixture keeps its types.

   It reports the line counts that set the ceilings below, and decides U1.
2. **L0, the integer model.** A pure refactor, with no behaviour change.
   - **The format type.** Declare `fixed union IntegerFormat: Int64Format`, with
     only Int64, so that L1's `UInt8Format` makes the compiler list every site
     that must handle it.
   - **The type.** `IntType` becomes `IntegerType(Int64Format)` in both
     `TypeRef` unions.
   - **The operations.** They carry the format: `IntegerAdd(IntegerFormat)`,
     and the rest.
   - **One owner per fact.** Every fact that depends on the format comes from
     one exhaustive, single-arm function in the phase that owns it. Find the
     sites by searching for `IntType` under `blorp/src`: about 18 exhaustive
     `TypeRef` matches and 6 operation matches, of which these depend on the
     format:
     - the C type, the List element key and suffix;
     - the type hash, which keeps `INT_TYPE_HASH`, so names stay the same;
     - the primitive, and the source name `Int`;
     - whether a literal value fits, for Int literal patterns in check and
       verify;
     - in `render.brp`, the type's spelling, the "Int parameters cannot be
       called" message, and the declaration-to-type match;
     - the operation constructors in `signatures.brp`, and emit's helper names
       (`blorp_int_add` and the rest), chosen by a nested exhaustive match.

     These are the places L1 adds its `UInt8Format` arm.
   - **Wildcards.** `IntegerType(_)` remains only where a fact holds for every
     integer format.
   - **Role names.** `BuiltinTypeRole`'s variants become `IntRole`,
     `FloatRole`, `StringRole`, `VoidRole` and `ListRole`, so they no longer
     share spellings with `TypeRef`'s.
   - **The test rename.** It must also add the `IntegerFormat(Int64Format)`
     import. It shrank from about 1,117 lines to 151 lines in 35 files when
     `824f3d4ee` deleted 329 unparsable old-syntax tests.
   - **Proof.** Fixed-input self C is byte-identical, and all e2e fixtures
     give identical output.
   - **Execution, 2026-11-08 (landed).** Both TypeRefs and all eight
     integer operations carry the sole Int64 format. Format-dependent facts
     are exhaustive at their owning phases; generic layout and ownership
     consumers ignore the payload. The focused active selection passes
     322 callbacks in 32 suites, including nine new callbacks. Six mutation
     witnesses fail as intended and were restored. Matched fixed-input
     allocations are unchanged and median instructions increase 0.013792%; all
     eight C outputs are identical. Own-source allocations increase
     0.207757%; one normal instruction observation increases 0.168146%.
     Full local gates, final reviews and four-platform CI pass;
     the report records raw paths, provenance and failed deferred selections.
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
   - **Execution, 2026-11-12.** `IntegerFormat` moved to `syntax.brp`, so the
     parser reads the format from `type UInt8 = builtin` and the `uint8.*`
     labels, and the parsed operations carry it. `UInt8Format` has an arm in
     every projection L0 made. The conversions are one
     `IntegerConvert(source, target)`, emitted as a C cast, behind
     `uint8.to_int` and `int.wrap_to_uint8`. A literal whose expectation is
     an unsolved variable gets an `IntegerLiteralSlot` with an integer-only
     state; it defaults to Int when its call, variant, record or list
     finishes, when lambda resolution stalls, and at publication. Its range
     is checked once its format is fixed. A literal defaults before receiver
     selection sees it, so `7.describe()` picks Int's `describe` over
     String's. The byte natives share the read and atomic-replace helpers
     with their text forms through `SystemRuntime.shared`, and use the read
     and write errno masks.
     - Lines: production +1,165 −315 (+850 net) for L1, after a
       preparatory commit that drops `SystemRuntime.posix_declarations`
       (−69 net). Tests +2,396 −168 (+2,228 net).
     - Cost against `aa9d5feaf`, from `blorp/scripts/self-compile-cost`
       with 11 rounds: fixed input instructions +0.100% and allocations
       +0.015%; own source instructions +1.31% and allocations +1.24%. The
       fixed-input C differs only in the file-system runtime: the read and
       atomic-replace helpers are emitted once, ahead of the operations that
       share them, and `read_text` and `write_text` call the new path
       helpers. The program's own functions are unchanged.
     - **Keith's ruling, 2026-11-11: production ceiling +700 → about +870.**
       S0's table did not foresee the deferred literal's full size (about 300
       lines against 225: slot origins, integer-only unification, four
       defaulting points and the range check) or the plumbing that lets the
       U4 help name an Int local declared from a lone literal (about 95
       lines through `scope`, `bodies`, `InferenceUse` and the conflict).
     - **Coordinator budget correction, 2026-11-12: e2e allocation ceilings
       `fs_write` 210,082 → 210,212 and `accepted_generic_head` 4,684 →
       4,693.** A deferred integer literal costs about 8 allocations, from
       inference unification and defaulting, and the seeded `UInt8` word,
       the shared-fragment selection and the List key's format suffix cost
       13 to 20 more per compile. Main had already used most of the two
       ceilings' headroom: it measured 209,917 and 4,681.
     - `lookup_errors/append_modules` now pins 1684 strict allocations, up
       from 1677. The fixture builds the compiler's own seeded name
       table, and seeding `UInt8` by identity adds seven allocations there;
       the 66-allocation eager-error regression it guards against would
       still fail it.
     - Gates: `make -C blorp test INSTRUCTION_CHECK=on`,
       `scripts/blorp-fixpoint --prove` (714 fixture pairs identical),
       `test_bootstrap.sh` and `git diff --check` pass. Five oracles were
       proved by breaking them: the range check, the Int default, the
       integer-only waiting literal, wrapping and literal emission.
4. **L2, seed rotation** onto L1: a plain rotation (`scripts/README.md`,
   "Rotating the seed pin"). The seed family switch to `blorp` and the move to
   the `compile INPUT --library-root DIR -o OUTPUT` command line landed with
   the modules plan's landing 6, so L2 changes only the pin.
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

Keith approved the S0 spike's ceilings on 2026-11-07:

| Landing | Production lines | Self-compile allocations and instructions | Fixed input |
| --- | --- | --- | --- |
| L0 | at most 550 gross changed / +180 net | at most +0.3% | self C byte-identical; allocations +0; instructions at most +0.1% |
| L1 | at most +700 compiler lines | at most +2.0% | instructions at most +0.2%; allocations at most +0.05% |
| L3 | library lines reported | at most +0.3% | — |
| L4 | compiler call sites only | at most +0.1% | — |

L1's self-compile ceiling is high because compiling the added source alone
costs about 0.3% per 100 lines, so the fixed-input ceiling is what guards the
new machinery's own cost.

**L0's corrected line allowance.** The coordinator set at most 550 lines
added plus removed and +180 net over `blorp/src`, under Keith's standing
delegation for routine budget corrections. The spike's old compact layout
and incomplete format projections understated the canonical formatted scope.
The implementation is +301 −164: 465 gross changed and +137 net production
lines. Test changes are separate: +441 −179, 620 gross and +262 net, including
the mechanical migration and nine new callbacks. No performance exception
was needed; the original allocation and instruction caps remain unchanged.

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
  `TypeRef`, such as the formatter (`src/format/`). L0 must
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
