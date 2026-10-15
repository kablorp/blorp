# Library parity: what `blorp_2/src` needs from both libraries

Until the fixpoint, the host compiler builds `blorp_2/src` against
`standard_library/src/` while the pilot compiles programs against
`blorp_2/standard_library_temp/`. The source may therefore use only library
functions that exist in both, with the same module name, function name and
signature. This table is the authority for that set. It drives the ML and M6
increments; no row may be MISSING when M6 exits.

Taken at `ba57e368a` (2026-10-15). Regenerate it when `src` gains or loses a
library dependency.

## Milestones

The milestone names below come from the self-compile plan, which is pending
adoption into [ROADMAP.md](ROADMAP.md). As this document uses them:

- **M0**: foundation closeout; includes removing the `+` operator sites from `src`.
- **M1b** (the "namespace" milestone): `private`, module aliases and qualified names. Part A (aliases, `private`, qualified values and types) landed 2026-10-15; qualified pattern heads remain.
- **ML** (the "list intrinsics" milestone): List construction intrinsics (`append`, `set`, `concat`, the list literal).
- **M2** (the "join" milestone): non-tail matches, `if`, `and`/`or`/`not`, `?=`, local type annotations.
- **M3** (the "loops" milestone): loops with managed carried values (`for`, `while`, `break`, `a..b`).
- **M4** (the "recursive-types" milestone): recursive types and opaque types.
- **M5**: module-level constants with literal initializers, including in library modules.
- **M6**: the library and shell increment this table drives; its exit is no MISSING row.
- **M7**: lambdas at known callees; `pure (T) -> U` parameter types in signatures.

## Method

Every row comes from the host compiler's own resolution, not from names:

1. `bin/blorp compile --no-format --stop-after=lower --dump-core-after=lower
   --dump-core-file=core_lower.json blorp_2/src/main.brp` dumps the host's Core
   after lowering as JSON. Each call node carries its callee's `def_id`; each
   declaration carries its defining file. A script walked every call node whose
   span lies under `blorp_2/src/`, followed the `def_id` to its declaration, and
   kept the calls whose declaration lives under `standard_library/src/`. UFCS and
   alias-qualified forms resolve to the same declaration and are counted together.
   The host resolves `to_int` and `to_char` as builtin conversions without a
   library declaration, and reads `INT_MAX`/`INT_MIN` as module members; those
   four were counted by grep over `src` (`\bto_int(`, `\bto_char(`, `INT_MAX`,
   `INT_MIN`) and their declarations opened in `char.brp` and `int.brp`.
2. Operators were found by a text scan of all 34 files with comments and string
   and Char literals removed, so `"a + b"` and `'+'` do not count.
3. Every host signature below was read from `standard_library/src/<module>.brp` at
   the line given; every twin was read from the 124 lines of
   `blorp_2/standard_library_temp/`.
4. Import blocks were listed with
   `grep -rn -A40 '^import:' blorp_2/src` and checked against the rows: every
   host module imported by name (`int`, `float`, `string`, `list`, `option`,
   `result`, `path`, `system`) appears below, plus `io` (reached through the host
   prelude's `print_error`) and `char` (reached through the host's `to_int`
   builtin).

A use is one resolved call, constant reference or operator site. The host's own
desugarings (`?=` to `blorp_result_err`, 668 sites; derived record equality;
`for`/`while`) are not library uses and are excluded.

Classification:

- **exists**: in the temp library now, same module, name and signature.
- **intrinsic**: touches representation or the machine and no Blorp expression
  over the other rows implements it; the temp library gets a `builtin(...)` body.
- **blorp**: written in Blorp in the temp library over intrinsics and the language
  features the self-compile plan adds; the milestone whose feature it needs is named.
- **rename**: exists under another name or signature; which side changes is stated.
  Only host-accepted forms may enter `src`, so the temp side changes unless the
  host already accepts the alternative.

The twin column gives the temp declaration (`module.name(signature)`) or MISSING.
"narrowed" marks a twin whose signature is a monomorphic instance of the host's
generic one; `src` calls it only at that instance, so both sides accept the
source unchanged.

## The table

| host module | name | host signature (`standard_library/src/<module>.brp:line`) | uses | files | temp-library twin | classification |
| --- | --- | --- | --- | --- | --- | --- |
| char | to_int | `pure func to_int(val: Char) -> Int` (in `implements ToInt for Char`, char.brp:20) | 16 | lex, parse, emit (lex/lex.brp:184, emit/emit.brp:193) | MISSING | intrinsic (Char to code point); see note A on the call form |
| float | abs | `pure func abs(val: Float) -> Float` (`implements Absolute for Float`, float.brp:593) | 1 | emit/float_literal.brp:34 | MISSING | blorp over `copysign(value, 1.0)`; no milestone |
| float | copysign | `pure func copysign(x: Float, y: Float) -> Float` (float.brp:444) | 1 | emit/float_literal.brp:17 | MISSING | intrinsic (sign bit) |
| float | divide | `pure func divide(a: Float, b: Float) -> Float` (`implements Divisible for Float`, float.brp:635) | 1 | emit/float_literal.brp:40 | `float.divide(first: Float, second: Float) -> Float` | exists |
| float | equals | `pure func equals(a: Float, b: Float) -> Bool` (`implements Equatable for Float`, float.brp:651) | 1 | emit/float_literal.brp:28 | MISSING | intrinsic (IEEE comparison) |
| float | greater_than_or_equal | `pure func greater_than_or_equal(a: Float, b: Float) -> Bool` (`implements Orderable for Float`, float.brp:668) | 2 | emit/float_literal.brp:39, :62 | MISSING | blorp: `not less_than(a, b)` guarded by `is_nan` on both operands; promotion candidate |
| float | is_finite | `pure func is_finite(x: Float) -> Bool` (float.brp:503) | 3 | float_literal, parse, verify (emit/float_literal.brp:23, parse/parse.brp:510) | MISSING | intrinsic (float classification) |
| float | is_nan | `pure func is_nan(x: Float) -> Bool` (float.brp:475) | 1 | emit/float_literal.brp:21 | MISSING | intrinsic (float classification) |
| float | less_than | `pure func less_than(a: Float, b: Float) -> Bool` (`implements Orderable for Float`, float.brp:659) | 2 | emit/float_literal.brp:16, :43 | MISSING | intrinsic (Float ordering) |
| float | multiply | `pure func multiply(a: Float, b: Float) -> Float` (`implements Multipliable for Float`, float.brp:630) | 2 | emit/float_literal.brp:44, :56 | `float.multiply(first: Float, second: Float) -> Float` | exists |
| float | subtract | `pure func subtract(a: Float, b: Float) -> Float` (`implements Subtractable for Float`, float.brp:625) | 2 | emit/float_literal.brp:52, :63 | `float.subtract(first: Float, second: Float) -> Float` | exists |
| int | INT_MAX | `INT_MAX: Int = 9223372036854775807` (int.brp:205) | 2 | parse/parse.brp:477, utils/source.brp:44 | MISSING | blorp constant; needs M5 (constants in library modules) |
| int | INT_MIN | `INT_MIN: Int = -9223372036854775807 - 1` (int.brp:207) | 2 | parse/parse.brp:475, emit/emit.brp:161 | MISSING | blorp constant; needs M5; see note B on the literal |
| int | add | `pure func add(a: Int, b: Int) -> Int` (`implements Addable for Int`, int.brp:99) | 202 | 23 files (check/values.brp:49 uses, lex/lex.brp:23 uses) | `int.add(a: Int, b: Int) -> Int` | exists |
| int | divide | `pure func divide(a: Int, b: Int) -> Int` (`implements Divisible for Int`, int.brp:114) | 2 | lex/lex.brp:559, parse/parse.brp:454 | `int.divide(a: Int, b: Int) -> Int` | exists |
| int | equals | `pure func equals(a: Int, b: Int) -> Bool` (`implements Equatable for Int`, int.brp:130) | 131 | 23 files (verify/verify.brp:27 uses, check/values.brp:16 uses) | `int.equals(a: Int, b: Int) -> Bool` | exists |
| int | greater_than | `pure func greater_than(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:141) | 54 | 9 files (emit/emit.brp:190, check/values.brp:14 uses) | MISSING | blorp: `less_than(b, a)`; promotion candidate |
| int | greater_than_or_equal | `pure func greater_than_or_equal(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:147) | 18 | 7 files (own/own.brp:182, verify/verify.brp:6 uses) | MISSING | blorp: `not less_than(a, b)`; promotion candidate |
| int | less_than | `pure func less_than(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:138) | 40 | 14 files (emit/emit.brp:163, verify/verify.brp:10 uses) | MISSING | intrinsic (Int ordering) |
| int | less_than_or_equal | `pure func less_than_or_equal(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:144) | 7 | lex, parse, source (lex/lex.brp:180, utils/source.brp:45) | MISSING | blorp: `not less_than(b, a)`; promotion candidate |
| int | min | `pure func min(a: Int, b: Int) -> Int` (`implements Bounded for Int`, int.brp:82) | 4 | lex, parse (lex/lex.brp:583, parse/parse.brp:527) | MISSING | blorp: `match less_than(a, b)`; needs the `less_than` intrinsic only |
| int | multiply | `pure func multiply(a: Int, b: Int) -> Int` (`implements Multipliable for Int`, int.brp:109) | 3 | lex, parse (lex/lex.brp:291, parse/parse.brp:447) | `int.multiply(a: Int, b: Int) -> Int` | exists |
| int | not_equals | `pure func not_equals(a: Int, b: Int) -> Bool` (`implements Equatable for Int`, int.brp:133) | 7 | emit, own, verify (emit/emit.brp:363, verify/verify.brp:254) | MISSING | blorp: `match equals(a, b)`; no milestone |
| int | remainder | `pure func remainder(a: Int, b: Int) -> Int` (`implements Modulable for Int`, int.brp:119) | 1 | lex/lex.brp:554 | `int.remainder(a: Int, b: Int) -> Int` | exists |
| int | subtract | `pure func subtract(a: Int, b: Int) -> Int` (`implements Subtractable for Int`, int.brp:104) | 65 | 11 files (check/values.brp:17 uses, verify/verify.brp:9 uses) | `int.subtract(a: Int, b: Int) -> Int` | exists |
| int | to_char | `pure func to_char(val: Int) -> Char` (`implements ToChar for Int`, int.brp:174) | 1 | parse/parse.brp:588 | MISSING | intrinsic (code point to Char); see note A on the call form |
| int | to_string | `pure func to_string(val: Int) -> String` (`implements Stringable for Int`, int.brp:66) | 11 | check/render.brp:364, :372 | `int.to_string(value: Int) -> String` | exists |
| io | print_error | `func print_error[T:Stringable](value: T) -> Void` (io.brp:31) | 4 | main.brp:137, :144, :153, :158 | MISSING | intrinsic (shell: stderr); twin narrowed to `io.print_error(value: String) -> Void` like the existing `print`; see note C |
| list | any | `pure func any[T](self: List[T], pred: pure (T) -> Bool) -> Bool` (list.brp:572) | 4 | emit, verify (emit/emit.brp:204, verify/verify.brp:287) | MISSING | blorp; needs M7 (function-typed parameter) and M3 (loop) |
| list | append | `pure func append[T](self: List[T], elem: T) -> List[T]` (list.brp:104) | 268 | 23 files (namespace/namespace.brp:41 uses, check/values.brp:48 uses) | `list.append[T](values: List[T], value: T) -> List[T]` | exists (intrinsic; ML part 1) |
| list | concat | `pure func concat[T](a: List[T], b: List[T]) -> List[T]` (list.brp:534) | 22 | 7 files (parse/assemble.brp:138, specialize/specialize.brp:7 uses) | `list.concat[T](left: List[T], right: List[T]) -> List[T]` | exists (intrinsic; ML part 1) |
| list | contains | `pure func contains[T:Equatable](self: List[T], elem: T) -> Bool` (list.brp:764) | 3 | verify/verify.brp:925, check/methods.brp:387, lex/lex.brp (levels) | MISSING | blorp, narrowed to `list.contains(values: List[Int], value: Int) -> Bool` (all sites are `List[Int]`); needs M3 (loop) |
| list | get | `pure func get[T](self: List[T], index: Int) -> Option[T]` (list.brp:68) | 217 | 23 files (check/values.brp:51 uses, verify/verify.brp:32 uses) | `list.get[T](values: List[T], index: Int) -> Option[T]` | exists |
| list | is_empty | `pure func is_empty[T](self: List[T]) -> Bool` (list.brp:289) | 34 | 13 files (check/values.brp:7 uses, emit/emit.brp:6 uses) | MISSING | blorp: `int.equals(length(values), 0)`; no milestone |
| list | join | `pure func join(self: List[String], sep: String) -> String` (list.brp:1351) | 4 | emit, load, main (emit/emit.brp:1982, main.brp:123) | MISSING | blorp over `string.add`; needs M3 (loop); measured decision per the self-compile plan (emit joins thousands of fragments) |
| list | length | `pure func length(self: List[T]) -> Int` (`implements HasLength for List[T]`, list.brp:225) | 175 | 22 files (verify/verify.brp:39 uses, check/values.brp:36 uses) | `list.length[T](values: List[T]) -> Int` | exists |
| list | map | `pure func map[T, U](self: List[T], f: pure (T) -> U) -> List[U]` (list.brp:358) | 22 | 11 files (emit/emit.brp:457, own/own.brp:201) | MISSING | blorp; needs M7 and M3, over `append` |
| list | set | `pure func set[T](self: List[T], index: Int, elem: T) -> List[T]` (list.brp:189) | 47 | 8 files (check/values.brp:17 uses, verify/verify.brp:12 uses) | `list.set[T](values: List[T], index: Int, value: T) -> List[T]` | exists (intrinsic; ML part 1) |
| list | set_index | `pure func set_index[T](self: List[T], index: Int, elem: T) -> Option[List[T]]` (list.brp:111) | 1 | own/own.brp:619 | MISSING | blorp: bounds test over `length` then `set`; `set` exists since ML part 1 |
| list | sort_by | `pure func sort_by[T, K:Orderable](self: List[T], key_fn: pure (T) -> K) -> List[T]` (list.brp:614) | 3 | emit/emit.brp:1955, :1956, :1957 | MISSING | blorp, narrowed to `list.sort_by[T](values: List[T], key: pure (T) -> Int) -> List[T]` (all three keys are `Int`); a stable sort; needs M7 and M3 |
| list | take | `pure func take[T](self: List[T], n: Int) -> List[T]` (list.brp:786) | 2 | check/signatures.brp:259, lex/lex.brp (levels) | MISSING | blorp over `get`/`append`; needs M3 |
| option | and_then | `pure func and_then[T, U](self: Option[T], f: pure (T) -> Option[U]) -> Option[U]` (option.brp:138) | 1 | check/methods.brp:181 | MISSING | blorp (match); needs M7 |
| option | get_or | `pure func get_or[T](self: Option[T], default_val: T) -> T` (option.brp:85) | 8 | load, values (load/load.brp:166, check/values.brp:1057) | MISSING | blorp (match); no milestone |
| option | is_none | `pure func is_none[T](self: Option[T]) -> Bool` (option.brp:66) | 20 | 5 files (namespace/namespace.brp:8 uses, check/values.brp:6 uses) | MISSING | blorp (match); no milestone |
| option | is_some | `pure func is_some[T](self: Option[T]) -> Bool` (option.brp:50) | 24 | 9 files (emit/emit.brp:401, specialize/specialize.brp:5 uses) | MISSING | blorp (match); no milestone |
| option | map | `pure func map[T, U](self: Option[T], f: pure (T) -> U) -> Option[U]` (option.brp:109) | 10 | 5 files (check/render.brp:1023, utils/ids.brp:1 use) | MISSING | blorp (match); needs M7 |
| option | to_result | `pure func to_result[T, E](self: Option[T], error: E) -> Result[T, E]` (option.brp:204) | 116 | 18 files (check/values.brp:32 uses, specialize/specialize.brp:16 uses) | MISSING | blorp (match); no milestone |
| path | dirname | `pure func dirname(path: String) -> String` (path.brp:69) | 2 | load/load.brp:123, :126 | MISSING | blorp; needs M3 and Blorp helpers for the host's `ends_with`, `take_left`, `last_index_of_char` |
| path | join | `pure func join(a: String, b: String) -> String` (path.brp:41) | 6 | load/load.brp:81, :82, :83, :108 | MISSING | blorp over `starts_with`, `length`, `add`; no milestone beyond those rows |
| path | normalize | `pure func normalize(path: String) -> String` (path.brp:229) | 2 | load/load.brp:78, :371 | MISSING | blorp; needs M3 and Blorp helpers for the host's `split`, `is_absolute`, `join` |
| result | and_then | `pure func and_then[T, U, E](self: Result[T, E], f: pure (T) -> Result[U, E]) -> Result[U, E]` (result.brp:136) | 5 | render, values, load, verify (check/render.brp:764, verify/verify.brp:934) | MISSING | blorp (match); needs M7 |
| result | map | `pure func map[T, U, E](self: Result[T, E], f: pure (T) -> U) -> Result[U, E]` (result.brp:96) | 6 | render, values, own, verify (check/render.brp:769, own/own.brp:469) | MISSING | blorp (match); needs M7 |
| result | map_err | `pure func map_err[T, E, F](self: Result[T, E], f: pure (E) -> F) -> Result[T, F]` (result.brp:116) | 6 | main.brp:29 through :34 | MISSING | blorp (match); needs M7 |
| string | add | `pure func add(a: String, b: String) -> String` (`implements Addable for String`, string.brp:998) | 1 (reached by 456 `text.concat` calls) | utils/text.brp:13 | MISSING | intrinsic (String concatenation); see note D |
| string | append_int | `pure func append_int(self: String, value: Int) -> String` (string.brp:70) | 76 | 5 files (emit/emit.brp:59 uses, verify/verify.brp:11 uses) | MISSING | blorp: `add(self, int.to_string(value))`; no milestone |
| string | chars | `pure func chars(self: String) -> List[Char]` (string.brp:226) | 1 | emit/emit.brp:189 | MISSING | blorp over `get`/`append`; needs M3 and ML; see note E |
| string | contains | `pure func contains(self: String, needle: String) -> Bool` (string.brp:129) | 3 | parse/parse.brp:505, :1325, :1331 | MISSING | blorp over `starts_with`/`substring`; needs M3 |
| string | from_char | `pure func from_char(c: Char) -> String` (string.brp:186) | 1 | parse/parse.brp:588 | MISSING | intrinsic (String from a Char; UTF-8 encoding) |
| string | get | `pure func get(self: String, index: Int) -> Option[Char]` (string.brp:421) | 8 | lex, parse (lex/lex.brp:205, parse/parse.brp:536) | MISSING | intrinsic (byte access); see note F |
| string | index_of | `pure func index_of(self: String, needle: String) -> Option[Int]` (string.brp:461) | 2 | parse/parse.brp:449, :564 | MISSING | blorp over `starts_with`/`substring`; needs M3 |
| string | is_empty | `pure func is_empty(self: String) -> Bool` (string.brp:483) | 1 | parse/parse.brp:561 | MISSING | blorp: `int.equals(length(value), 0)`; no milestone |
| string | length | `pure func length(self: String) -> Int` (string.brp:200) | 24 | lex, parse, text, emit (lex/lex.brp:285, utils/text.brp:9) | `string.length(value: String) -> Int` | exists |
| string | lower | `pure func lower(self: String) -> String` (string.brp:301) | 1 | parse/parse.brp:559 | MISSING | blorp over `get`/`to_int`/`to_char`/`from_char`/`add`; needs M3; see note E |
| string | parse_float | `pure func parse_float(self: String) -> Option[Float]` (string.brp:395) | 1 | parse/parse.brp:508 | `string.parse_float(text: String) -> Option[Float]` | exists |
| string | starts_with | `pure func starts_with(self: String, prefix: String) -> Bool` (string.brp:101) | 4 | load, parse, text (utils/text.brp:9, parse/parse.brp:463) | MISSING | blorp over `get`; needs M3 (or recursion today) |
| string | substring | `pure func substring(self: String, start: Int, len: Int) -> String` (string.brp:87) | 19 | lex, parse, main, float_literal (lex/lex.brp:367, parse/parse.brp:14 uses) | MISSING | blorp over `get`/`from_char`/`add`; needs M3; see note E on cost |
| system | getcwd | `func getcwd() -> String` (system.brp:122) | 1 | load/load.brp:368 | MISSING | intrinsic (shell) |
| system | read_file | `func read_file(path: String) -> Result[String, String]` (system.brp:35) | 1 | load/load.brp:161 | MISSING | intrinsic (shell) |
| system | write_file | `func write_file(path: String, content: String) -> Result[Void, String]` (system.brp:40) | 1 | main.brp:142 | MISSING | intrinsic (shell) |

Types reached through the host prelude: `Int`, `Float`, `String`, `Void`,
`List`, `Bool(True, False)`, `Option(Some, None)` and `Result(Ok, Err)` exist in
`standard_library_temp/_base.brp` under the same names. `Char` (51 Char literals
in `src`, the `string.get`, `chars`, `from_char`, `to_int` and `to_char` rows) is
MISSING from `_base` and is an intrinsic type. `main(args: List[String]) -> Int`
(argv and exit status) is the same contract in both.

### Operators the source still uses

| operator | host meaning | sites | classification |
| --- | --- | --- | --- |
| `+` on String | `implements Addable for String` (`string.add`) | 10: check/render.brp:332, :408, :497, :518, :553, :665, :675, :685; emit/emit.brp:2194; parse/parse.brp:1153 (inside the `BUILTIN_LABEL_HELP` initializer, lines 1151 to 1153) | forbidden by `blorp_2/AGENTS.md`; rewrite each as `concat` from `utils/text` (which is `string.add`). The self-compile plan's "one literal at parse.brp:1151" undercounts: all ten are string-literal continuations across lines. |
| `==`, `!=`, `<`, `>`, `<=`, `>=`, `-`, `*`, `/`, `%` | trait operators | 0 | none left (the 51 `equal` nodes in the host's Core are derived record equality the host synthesizes, not source text) |
| `and` / `or` / `not` | language keywords | 134 / 40 / 91 | not library; M2 desugars them to matches on the designated `Bool` |
| `?=` | language | 668 | not library; M2 |
| `[a, b, ...]` | list literal | 309 `list_construct` nodes in the host's Core (including empty `[]`) | exists (ML part 2: one fresh root, n stores) |

## 1. The intrinsic set this implies for ML and M6

Proposed temp-library declarations (host parameter names kept where the host
has a plain function; the host's trait-impl methods become plain functions
under the same name, as the temp `int.brp` already does for `add`):

ML (list construction; `append`, `set` and `concat` landed in part 1, the literal in part 2):

```blorp
-- list.brp
pure func append[T](values: List[T], value: T) -> List[T]:
	builtin("list.append")
pure func set[T](values: List[T], index: Int, value: T) -> List[T]:
	builtin("list.set")
pure func concat[T](left: List[T], right: List[T]) -> List[T]:
	builtin("list.concat")
-- plus the list literal `[a, b]` / `[]`: one fresh root of n stored occurrences
```

M6 (representation and machine):

```blorp
-- _base.brp
type Char = builtin

-- int.brp
pure func less_than(a: Int, b: Int) -> Bool:              builtin("int.less_than", True, False)
pure func to_char(value: Int) -> Char:                    builtin("int.to_char")

-- char.brp (new module)
pure func to_int(value: Char) -> Int:                     builtin("char.to_int")

-- float.brp
pure func equals(a: Float, b: Float) -> Bool:                   builtin("float.equals", True, False)
pure func less_than(a: Float, b: Float) -> Bool:                builtin("float.less_than", True, False)
pure func is_nan(x: Float) -> Bool:                             builtin("float.is_nan", True, False)
pure func is_finite(x: Float) -> Bool:                          builtin("float.is_finite", True, False)
pure func copysign(x: Float, y: Float) -> Float:                builtin("float.copysign")

-- string.brp
pure func add(a: String, b: String) -> String:            builtin("string.add")
pure func get(text: String, index: Int) -> Option[Char]:  builtin("string.get", Some, None)
pure func from_char(c: Char) -> String:                   builtin("string.from_char")

-- io.brp
func print_error(value: String) -> Void:                  builtin("string.print_error")

-- system.brp (new module; `main.brp` and `load.brp` only)
func getcwd() -> String:                                        builtin("system.getcwd")
func read_file(path: String) -> Result[String, String]:         builtin("system.read_file", Ok, Err)
func write_file(path: String, content: String) -> Result[Void, String]:
	builtin("system.write_file", Ok, Err)
```

That is 18 intrinsic functions (3 in ML, 15 in M6) and one intrinsic type.
Everything else in the table is Blorp over these, `int.equals`/`add`/`subtract`,
`list.get`/`length`, `string.length` and `match`. Four rows are derivable and
classified blorp, but are candidates for later promotion to intrinsics for
codegen quality once measured: `int.greater_than`, `int.greater_than_or_equal`,
`int.less_than_or_equal` (one `less_than` each) and `float.greater_than_or_equal`
(`less_than` plus `is_nan`). `list.concat` was promoted in ML part 1: a loop over
`append` would copy the growing result once per element.

## 2. Rows where the host signature is awkward for the pilot

- **A. `to_int` and `to_char` call form.** `src` calls them bare (`to_int('a')`,
  lex/lex.brp:196; `to_char(digits.scalar)`, parse/parse.brp:588) with no import:
  the host resolves them as builtin conversion methods. The pilot has no implicit
  bare functions: direct calls need named imports
  (`standard_library_temp/README.md`). So `src` must call them through an
  import, and the host must accept that form for a method it declares inside a
  trait implementation. It does: this probe compiled under
  `bin/blorp run --no-format` (the same form `src` already uses for
  `TextOps.add` and `IntOps.less_than`):

  ```blorp
  import:
      char as CharOps
      int as IntOps
      string as StringOps

  func main() -> Int:
      code: Int = CharOps.to_int('a')
      back: Char = IntOps.to_char(IntOps.add(code, 1))
      print(StringOps.add(StringOps.from_char(back), "!"))
      0
  ```

  Recommendation: `src` switches the 17 sites to
  `CharOps.to_int(c)` with `char as CharOps` and `IntOps.to_char(n)`; the temp
  gains `char.brp` with `to_int` and `int.to_char`.
- **B. `INT_MIN`.** The host initializer is the expression
  `-9223372036854775807 - 1`, because the host lexer does not read the
  most-negative literal. M5 admits literal initializers only, so the temp
  `int.brp` needs the literal `-9223372036854775808`, which the pilot's lexer and
  checker must accept (the pilot already lexes `-` as part of a number token,
  lex/lex.brp:494). Both `src` uses compare against it (parse/parse.brp:475,
  emit/emit.brp:161). If the literal is rejected, the fallback is host-shaped:
  `src` computes it as `IntOps.subtract(IntOps.subtract(0, IntOps.INT_MAX), 1)`,
  which removes the `INT_MIN` row.
- **C. `io.print_error[T: Stringable]`.** The host is generic over `Stringable`;
  all four `src` sites pass a `String`. The temp twin is the concrete
  `print_error(value: String) -> Void`, exactly as the temp already narrowed
  `print`. `src` also reaches it through the host prelude without an import;
  the pilot needs `io: print_error` in `main.brp`'s import block, which the host
  accepts (its own prelude imports `io: ... print_error`).
- **D. `string.add` is only a trait method on the host.** `utils/text.concat`
  reaches it as `TextOps.add` (the alias form the host accepts for trait-impl
  methods). The temp declares a plain `add`; nothing in `src` changes. The 456
  `text.concat` calls (478 `.concat(` sites in `src` less the 22 that resolve to
  `list.concat`) and 76 `append_int` calls all land on this one intrinsic, so its
  cost (fresh allocation per call) is the measured decision the self-compile plan names for
  `concat`/`join`.
- **E. `substring`, `chars`, `lower`, `contains`, `index_of` written over
  `get`/`from_char`/`add`.** Each becomes O(n) Char allocations per call.
  `substring` has 19 uses and is how the lexer and parser take token text
  (lex/lex.brp:367, :375, :488; parse/parse.brp 14 sites). The self-compile plan's rule puts a
  byte-range copy on the representation side, so promote `substring` to an
  intrinsic (`builtin("string.substring")`) if a measurement on `src`-sized input
  shows the Blorp body dominating; the other four have one to three uses each
  and can stay Blorp. `chars` (one use, emit/emit.brp:189, to emit byte values) and
  `lower` (one use, parse/parse.brp:559, to fold hex digits) could instead be
  removed from `src` by looping over `StringOps.get` and comparing both cases,
  which deletes two rows.
- **F. `string.get -> Option[Char]`.** Kept as the host signature (the self-compile plan's
  "byte access returning Option" now matches it). All eight uses immediately
  `match` and most convert with `to_int`; the twin needs `Char` in `_base`. The
  alternative `byte_at -> Option[Int]` would need a host-library addition
  and is not recommended while `Char` stays.
- **Narrowed generics.** `list.contains[T: Equatable]` (both sites `List[Int]`),
  `list.sort_by[T, K: Orderable]` (all three keys `Int`) and `print_error`
  (note C) have no trait on the pilot side; the temp twins are the monomorphic
  instances the source uses. If `src` later calls them at another type the row
  changes, so the twins should name the instance in their doc comment.
- **Eight rows depend on M7, which the self-compile plan orders after M6:** `list.any`,
  `list.map`, `list.sort_by`, `option.map`, `option.and_then`, `result.map`,
  `result.map_err`, `result.and_then` need a `pure (T) -> U` parameter type in a
  temp-library signature. Either M7's function-type-in-signature lands before
  M6 exits or the M6 exit criterion is "no MISSING row except the eight M7
  rows". `list.set_index` (one use) and `string.chars`/`lower` (one use each) are
  cheaper to remove from `src` than to write; `set_index` is a bounds test over
  `length` followed by `set`.
- **`+` on String** has ten sites, not one (see the operator table); the M0
  source correction covers all ten.

## 3. Counts

| measure | count |
| --- | --- |
| rows (host module, name, signature) | 69 |
| exists | 17 |
| rename | 0 |
| blorp | 37 |
| intrinsic | 18 |
| MISSING twins (blorp + intrinsic) | 52 |
| blorp rows that are promotion candidates | 4 |
| narrowed twins among those | 3 (`list.contains`, `list.sort_by`, `io.print_error`) |
| rows needing M7 | 8 |
| rows needing M5 | 2 |
| host modules used by `src` | 10 (`char`, `float`, `int`, `io`, `list`, `option`, `path`, `result`, `string`, `system`) |
| host modules the temp library must gain | 5 (`char`, `option`, `path`, `result`, `system`), plus `Char` in `_base` |
| operator sites to remove from `src` | 10 (`+` on String) |
