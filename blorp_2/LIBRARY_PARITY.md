# Library parity: what `blorp_2/src` needs from both libraries

Until the fixpoint, the host compiler builds `blorp_2/src` against its selected
host library while the pilot compiles programs against
`blorp_2/standard_library/`. The source may therefore use only library
functions that exist in both, with the same module name, function name and
signature, including the explicitly documented monomorphic instances below.
This document owns that set. No required row may be MISSING when M6 exits.

**Scope update.** The table and counts below are a historical resolved snapshot
at `ba57e368a` (2026-10-15), not the final interface inventory. The
[current full accounting](STANDARD_LIBRARY_GAPS.md) records 65 called APIs,
35 absent names, two missing constants and parallel implementation ownership
at accepted main `1d02a6700` (2026-10-19). It supersedes the historical counts.
The
[source plan](BOOTSTRAP_SOURCE_PLAN.md) and [current roadmap](ROADMAP.md#m6-library-and-shell)
govern the independent Char/source work. The owner stopped the remaining
callback-removal migration. The current [Option/Result catalog](OPTION_RESULT_PLAN.md)
supersedes those rows/counts: nine pure APIs at 212 resolved compiler sites,
including four callback helpers. All nine library definitions are implemented;
`option.map`, `result.map`, `map_err` and `and_then` accept pure named callbacks
and forwarding. [Their API contracts](standard_library/README.md) preserve the
base union identities and bypass ownership. M7 lambdas/captures and explicit
compiler-source operation imports remain pending; library definitions alone do
not complete the compiler consumers or M6.
Int target-status rows now reflect signed ordering and scalar constants; source
counts remain historical. The target also supplies ordinary `max(Int, Int) -> Int`.
Refresh other interfaces at their own implementation boundary.

### Deferred List update naming

Both libraries currently expose `set(List[T], Int, T) -> List[T]` for replacement
that keeps the original value on an invalid index, and
`set_index(List[T], Int, T) -> Option[List[T]]` for checked replacement. Matching
interfaces are required because the same compiler source must build against
both libraries. The checked target implementation is an ordinary get/match wrapper.

**Later change:** rename checked `set_index` to `set`, and no-op-on-invalid
`set` to `set_or_keep`. Change both libraries and all compiler callers, tests and
docs together. A target-only rename breaks self-compilation; a source-only rename
breaks the host build. This coordinated rename is deferred, not implemented here.
See the [restoration report](../benchmarks/results/blorp_2_list_bootstrap_names_2026-10-18.md).

## Planned interface delta

| Source migration / interface | Bootstrap requirement |
| --- | --- |
| Char reads, literals and conversions | Replace with `string.byte_at(String, Int) -> Option[Int]` and `string.from_codepoint(Int) -> Option[String]`. Both matching host and target interfaces are implemented; host wrappers are validated with explicit source-library selection. Target phase/native/main and matched-cost evidence is in the [API acceptance report](../benchmarks/results/blorp_2_string_integer_apis_2026-10-16.md). Source Char/classification migration remains pending. Full-width scalar validation precedes narrowing, and Some[String] has ordinary owning payload transfer/destruction. |
| Parser alphabet classification | Private ASCII byte predicates replace all current String lower/index_of/contains callers, preserving empty-substring and malformed-token diagnostic behavior. Remove the historical rows only after resolved inventory confirms zero uses. |
| List/Option/Result callbacks and function types | Retain compiler callbacks. The [Option/Result plan](OPTION_RESULT_PLAN.md) owns its resolved nine-API subset and callable prerequisites; List demand remains a separate inventory. No remaining HOF-removal campaign is planned. |
| First-order numeric, String and List operations | Remain required over valid UTF-8. Planned `string.slice(String, Int, Int) -> Option[String]` uses half-open byte offsets and rejects out-of-range or misaligned endpoints. Byte comparisons create no String. Measure join construction: host join uses capacity-aware append, not naive concat. |
| `system.get_current_directory() -> Result[String, String]` | Target adapter and native Result contract are implemented. Both branches own a fresh String; success is an exact nonempty absolute UTF-8 path, and invalid encoding returns Err. Storage grows as needed. Compiler-source migration from fixed-buffer `getcwd` remains pending. |
| `system.read_file(String) -> Result[String, String]` | Target adapter and native Result contract implemented. Exact counted UTF-8 preserves empty/CRLF/BOM/NUL contents; NUL paths reject before open. IO errors use saved numeric errno; one close attempt follows every open. Both branches own a fresh String. Invalid UTF-8 advises saving as UTF-8; the host also suggests read_bytes, unavailable in the target. Loader migration remains pending. |
| `system.write_file(String, String) -> Result[Void, String]` | Target contract: exact create/truncate counted write; reject NUL paths before open; Ok stores Void only after successful write and one close. Err owns fresh saved-errno text; write errors precede close errors. Partial output is allowed. Target NUL-path teaching text says `path contains embedded NUL; use a path without NUL`, while host says `string contains embedded NUL`. Main migration remains pending. |
| `io.print_error(String) -> Void` | Target concrete adapter and counted stderr helper implemented. Borrow String, return unmanaged Void; one message request, then LF only after a full transfer. Short/EINTR writes stop without LF or retry; host instead attempts LF after a short write. Shell migration remains pending; see note C. |
| `path.join`, `path.dirname`, `path.normalize` | Keep existing names and pure String signatures. ROADMAP pins empty children, all trailing separators, logical normalization and root behavior. No cosmetic synonyms or Path carrier. |

These seven OS/path functions plus the existing `main(args: List[String]) -> Int`
contract cover the shell/loader boundary. [ROADMAP](ROADMAP.md#seven-shell-and-path-functions)
owns their complete behavioral and failure contracts, the unchanged CLI,
relative-path acceptance and runtime ownership tests.

The String contract is valid UTF-8 everywhere, retaining byte lengths and spans.
Target-generated programs validate argv before argument-taking main; malformed
encoding reports a fixed ASCII diagnostic and exits 1 after prefix cleanup.
The internal `blorp_string_from_bytes` constructor requires already-valid UTF-8.
The [native file-admission pilot](BOOTSTRAP_SOURCE_PLAN.md#native-file-admission-pilot)
covers host `read_file`. Target filesystem admission, checked slicing and legacy
host argv/byte APIs remain pending.
Error messages must also satisfy the invariant. No public Bytes or ASCII type
is introduced.

The host normally uses an embedded library/runtime. Verify explicit
`compile --std-dir DIRECTORY` selection for new ordinary wrappers; project CWD
alone does not establish availability. That override cannot add embedded native
helpers or ownership declarations. A native addition needs a separately validated
supporting host, then a frozen matched measurement epoch. No hidden fallback or
second library implementation is authorized.

## Milestones

The milestones are defined in [ROADMAP.md](ROADMAP.md). As this document uses them:

- **M0**: foundation closeout; includes removing the `+` operator sites from `src`.
- **M1b** (the "namespace" milestone): `private`, module aliases and qualified names. Part A (aliases, `private`, qualified values and types) landed 2026-10-15; qualified pattern heads remain.
- **ML** (the "list intrinsics" milestone): List construction intrinsics (`append`, `set`, `concat`, the list literal).
- **M2** (the "join" milestone): non-tail matches, `if`, `and`/`or`/`not`, `?=`, local type annotations.
- **M3** (the "loops" milestone): List/while loops with managed carried values and explicit exits. Six source ranges migrate to Int loops; range execution is not a planned prerequisite afterward.
- **M4** (the "recursive-types" milestone): recursive types and opaque types.
- **M5**: module-level constants with literal initializers, including in library modules.
- **M6**: the library and shell increment this table drives; its exit is no MISSING row.
- **M7**: pure lambdas at known callees and function-typed parameters, including managed immutable captures; parsing is implemented, semantic execution remains required.

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
   `blorp_2/standard_library/`.
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
| int | INT_MAX | `INT_MAX: Int = 9223372036854775807` (int.brp:205) | 2 | parse/parse.brp:477, utils/source.brp:44 | `int.INT_MAX: Int = 9223372036854775807` | ordinary closed scalar literal |
| int | INT_MIN | `INT_MIN: Int = -9223372036854775807 - 1` (int.brp:207) | 2 | parse/parse.brp:475, emit/emit.brp:161 | `int.INT_MIN: Int = -9223372036854775808` | ordinary closed scalar literal; see note B |
| int | add | `pure func add(a: Int, b: Int) -> Int` (`implements Addable for Int`, int.brp:99) | 202 | 23 files (check/values.brp:49 uses, lex/lex.brp:23 uses) | `int.add(a: Int, b: Int) -> Int` | exists |
| int | divide | `pure func divide(a: Int, b: Int) -> Int` (`implements Divisible for Int`, int.brp:114) | 2 | lex/lex.brp:559, parse/parse.brp:454 | `int.divide(a: Int, b: Int) -> Int` | exists |
| int | equals | `pure func equals(a: Int, b: Int) -> Bool` (`implements Equatable for Int`, int.brp:130) | 131 | 23 files (verify/verify.brp:27 uses, check/values.brp:16 uses) | `int.equals(a: Int, b: Int) -> Bool` | exists |
| int | greater_than | `pure func greater_than(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:141) | 54 | 9 files (emit/emit.brp:190, check/values.brp:14 uses) | `int.greater_than(a: Int, b: Int) -> Bool` | ordinary `less_than(b, a)` |
| int | greater_than_or_equal | `pure func greater_than_or_equal(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:147) | 18 | 7 files (own/own.brp:182, verify/verify.brp:6 uses) | `int.greater_than_or_equal(a: Int, b: Int) -> Bool` | ordinary Bool match over `less_than(a, b)` |
| int | less_than | `pure func less_than(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:138) | 40 | 14 files (emit/emit.brp:163, verify/verify.brp:10 uses) | `int.less_than(a: Int, b: Int) -> Bool` | signed64 intrinsic |
| int | less_than_or_equal | `pure func less_than_or_equal(a: Int, b: Int) -> Bool` (`implements Orderable for Int`, int.brp:144) | 7 | lex, parse, source (lex/lex.brp:180, utils/source.brp:45) | `int.less_than_or_equal(a: Int, b: Int) -> Bool` | ordinary Bool match over `less_than(b, a)` |
| int | min | `pure func min(a: Int, b: Int) -> Int` (`implements Bounded for Int`, int.brp:82) | 4 | lex, parse (lex/lex.brp:583, parse/parse.brp:527) | `int.min(a: Int, b: Int) -> Int` | ordinary Bool match over `less_than(a, b)` |
| int | multiply | `pure func multiply(a: Int, b: Int) -> Int` (`implements Multipliable for Int`, int.brp:109) | 3 | lex, parse (lex/lex.brp:291, parse/parse.brp:447) | `int.multiply(a: Int, b: Int) -> Int` | exists |
| int | not_equals | `pure func not_equals(a: Int, b: Int) -> Bool` (`implements Equatable for Int`, int.brp:133) | 7 | emit, own, verify (emit/emit.brp:363, verify/verify.brp:254) | `int.not_equals(a: Int, b: Int) -> Bool` | ordinary Bool match over `equals(a, b)` |
| int | remainder | `pure func remainder(a: Int, b: Int) -> Int` (`implements Modulable for Int`, int.brp:119) | 1 | lex/lex.brp:554 | `int.remainder(a: Int, b: Int) -> Int` | exists |
| int | subtract | `pure func subtract(a: Int, b: Int) -> Int` (`implements Subtractable for Int`, int.brp:104) | 65 | 11 files (check/values.brp:17 uses, verify/verify.brp:9 uses) | `int.subtract(a: Int, b: Int) -> Int` | exists |
| int | to_char | `pure func to_char(val: Int) -> Char` (`implements ToChar for Int`, int.brp:174) | 1 | parse/parse.brp:588 | MISSING | intrinsic (code point to Char); see note A on the call form |
| int | to_string | `pure func to_string(val: Int) -> String` (`implements Stringable for Int`, int.brp:66) | 11 | check/render.brp:364, :372 | `int.to_string(value: Int) -> String` | exists |
| io | print_error | `func print_error[T:Stringable](value: T) -> Void` (io.brp:31) | 4 | main.brp:137, :144, :153, :158 | MISSING | intrinsic (shell: stderr); twin narrowed to `io.print_error(value: String) -> Void` like the existing `print`; see note C |
| list | any | `pure func any[T](self: List[T], pred: pure (T) -> Bool) -> Bool` (list.brp:572) | 4 | emit, verify (emit/emit.brp:204, verify/verify.brp:287) | `list.any[T](values: List[T], predicate: pure (T) -> Bool) -> Bool` | ordinary named/forwarded callbacks; balanced recursion; lambda consumers remain queued |
| list | append | `pure func append[T](self: List[T], elem: T) -> List[T]` (list.brp:104) | 268 | 23 files (namespace/namespace.brp:41 uses, check/values.brp:48 uses) | `list.append[T](values: List[T], value: T) -> List[T]` | exists (intrinsic; ML part 1) |
| list | concat | `pure func concat[T](a: List[T], b: List[T]) -> List[T]` (list.brp:534) | 22 | 7 files (parse/assemble.brp:138, specialize/specialize.brp:7 uses) | `list.concat[T](left: List[T], right: List[T]) -> List[T]` | exists (intrinsic; ML part 1) |
| list | contains | `pure func contains[T:Equatable](self: List[T], elem: T) -> Bool` (list.brp:764) | 2 | verify/verify.brp:1080, lex/lex.brp:1156 | `contains(List[Int], Int) -> Bool`; generic `contains_with[A]` | ordinary supplied-equality source; temporary Int adapter; O(n) work and linear O0 stack; [acceptance report](../benchmarks/results/blorp_2_list_contains_2026-10-19.md), no M3 dependency |
| list | get | `pure func get[T](self: List[T], index: Int) -> Option[T]` (list.brp:68) | 217 | 23 files (check/values.brp:51 uses, verify/verify.brp:32 uses) | `list.get[T](values: List[T], index: Int) -> Option[T]` | exists |
| list | is_empty | `pure func is_empty[T](self: List[T]) -> Bool` (list.brp:289) | 34 | 13 files (check/values.brp:7 uses, emit/emit.brp:6 uses) | MISSING | blorp: `int.equals(length(values), 0)`; no milestone |
| list | join | `pure func join(self: List[String], sep: String) -> String` (list.brp:1351) | 13 | emit, load, main, parse (emit/emit.brp:702, :1524, :1661, :1748, :1875, :2322, :2392, :2416, :2477, :2585, load/load.brp:363, main.brp:123, parse/parse.brp:1034) | MISSING | blorp over `string.add`; needs M3 (loop); measured decision per the self-compile plan (emit joins thousands of fragments) |
| list | length | `pure func length(self: List[T]) -> Int` (`implements HasLength for List[T]`, list.brp:225) | 175 | 22 files (verify/verify.brp:39 uses, check/values.brp:36 uses) | `list.length[T](values: List[T]) -> Int` | exists |
| list | map | `pure func map[T, U](self: List[T], f: pure (T) -> U) -> List[U]` (list.brp:358) | 22 | 11 files (emit/emit.brp:457, own/own.brp:201) | `list.map[T, U](values: List[T], callback: pure (T) -> U) -> List[U]` | ordinary named/forwarded callbacks; temporary O(n log n) List copying; lambda consumers remain queued |
| list | set | `pure func set[T](self: List[T], index: Int, elem: T) -> List[T]` (list.brp:189) | 47 | 8 files (check/values.brp:17 uses, verify/verify.brp:12 uses) | `list.set[T](values: List[T], index: Int, value: T) -> List[T]` | exists; host-compatible name |
| list | set_index | `pure func set_index[T](self: List[T], index: Int, elem: T) -> Option[List[T]]` (list.brp:111) | 1 | own/own.brp:619 | `list.set_index[T](values: List[T], index: Int, value: T) -> Option[List[T]]` | exists; ordinary get/match wrapper |
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
| string | add | `pure func add(a: String, b: String) -> String` (`implements Addable for String`, string.brp:998) | 1 (reached by 456 `text.concat` calls) | utils/text.brp:13 | `string.add(left: String, right: String) -> String` | intrinsic; borrowed operands, one fresh counted String; phase/native/real-main and matched-cost gates pass ([report](../benchmarks/results/blorp_2_string_concat_2026-10-18.md)); see note D |
| string | append_int | `pure func append_int(self: String, value: Int) -> String` (string.brp:70) | 76 | 5 files (emit/emit.brp:59 uses, verify/verify.brp:11 uses) | `string.append_int(String, Int) -> String` | ordinary wrapper; see [API reference](README.md#counted-string-operations) |
| string | chars | `pure func chars(self: String) -> List[Char]` (string.brp:226) | 1 | emit/emit.brp:189 | MISSING | blorp over `get`/`append`; needs M3 and ML; see note E |
| string | contains | `pure func contains(self: String, needle: String) -> Bool` (string.brp:129) | 3 | parse/parse.brp:505, :1325, :1331 | MISSING | blorp over `starts_with`/`substring`; needs M3 |
| string | from_char | `pure func from_char(c: Char) -> String` (string.brp:186) | 1 | parse/parse.brp:588 | MISSING | intrinsic (String from a Char; UTF-8 encoding) |
| string | get | `pure func get(self: String, index: Int) -> Option[Char]` (string.brp:421) | 8 | lex, parse (lex/lex.brp:205, parse/parse.brp:536) | MISSING | intrinsic (byte access); see note F |
| string | index_of | `pure func index_of(self: String, needle: String) -> Option[Int]` (string.brp:461) | 2 | parse/parse.brp:449, :564 | MISSING | blorp over `starts_with`/`substring`; needs M3 |
| string | is_empty | `pure func is_empty(self: String) -> Bool` (string.brp:483) | 1 | parse/parse.brp:561 | MISSING | blorp: `int.equals(length(value), 0)`; no milestone |
| string | length | `pure func length(self: String) -> Int` (string.brp:200) | 24 | lex, parse, text, emit (lex/lex.brp:285, utils/text.brp:9) | `string.length(value: String) -> Int` | exists |
| string | lower | `pure func lower(self: String) -> String` (string.brp:301) | 1 | parse/parse.brp:559 | MISSING | blorp over `get`/`to_int`/`to_char`/`from_char`/`add`; needs M3; see note E |
| string | parse_float | `pure func parse_float(self: String) -> Option[Float]` (string.brp:395) | 1 | parse/parse.brp:508 | `string.parse_float(text: String) -> Option[Float]` | exists |
| string | starts_with | `pure func starts_with(self: String, prefix: String) -> Bool` (string.brp:101) | 4 | load, parse, text (utils/text.brp:9, parse/parse.brp:463) | `string.starts_with(value: String, prefix: String) -> Bool` | ordinary helper; combined Starts/List-helper native gate passed; exact counted bytes, temporary linear native stack; source consumers remain queued |
| string | substring | `pure func substring(self: String, start: Int, len: Int) -> String` (string.brp:87) | 19 | lex, parse, main, float_literal (lex/lex.brp:367, parse/parse.brp:14 uses) | MISSING | blorp over `get`/`from_char`/`add`; needs M3; see note E on cost |
| system | getcwd | `func getcwd() -> String` (system.brp:122) | 1 | load/load.brp:368 | MISSING | intrinsic (shell) |
| system | read_file | `func read_file(path: String) -> Result[String, String]` (system.brp:35) | 1 | load/load.brp:161 | MISSING | intrinsic (shell) |
| system | write_file | `func write_file(path: String, content: String) -> Result[Void, String]` (system.brp:40) | 1 | main.brp:142 | MISSING | intrinsic (shell) |

Types reached through the host prelude: `Int`, `Float`, `String`, `Void`,
`List`, `Bool(True, False)`, `Option(Some, None)` and `Result(Ok, Err)` exist in
`standard_library/_base.brp` under the same names. `Char` (51 Char literals
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

ML (list construction; `append`, the no-op-on-invalid update and `concat` landed
in part 1, the literal in part 2; the update retains the host name `set`):

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

-- int.brp (signed ordering now exists; Char conversion remains planned)
pure func to_char(value: Int) -> Char:                    builtin("int.to_char")

-- char.brp (new module)
pure func to_int(value: Char) -> Int:                     builtin("char.to_int")

-- float.brp
pure func equals(a: Float, b: Float) -> Bool:                   builtin("float.equals")
pure func less_than(a: Float, b: Float) -> Bool:                builtin("float.less_than")
pure func is_nan(x: Float) -> Bool:                             builtin("float.is_nan")
pure func is_finite(x: Float) -> Bool:                          builtin("float.is_finite")
pure func copysign(x: Float, y: Float) -> Float:                builtin("float.copysign")

-- string.brp
pure func add(a: String, b: String) -> String:            builtin("string.add")
pure func get(text: String, index: Int) -> Option[Char]:  builtin("string.get")
pure func from_char(c: Char) -> String:                   builtin("string.from_char")

-- io.brp
func print_error(value: String) -> Void:                  builtin("string.print_error")

-- system.brp (new module; `main.brp` and `load.brp` only)
func getcwd() -> String:                                        builtin("system.getcwd")
func read_file(path: String) -> Result[String, String]:         builtin("system.read_file")
func write_file(path: String, content: String) -> Result[Void, String]:
	builtin("system.write_file")
```

Builtins returning Bool, Option or Result name only their operation: their
contracts return the foundation's designated unions, so no body binds
constructors.

The original plan listed 18 intrinsic functions (3 in ML, 15 in M6) and one intrinsic type; signed Int ordering now exists.
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
  (`standard_library/README.md`). So `src` must call them through an
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
- **B. `INT_MIN`.** The host spells its initializer as arithmetic, while the
  target declares the supported literal `-9223372036854775808`. Ordinary selected
  and qualified constant reads publish checked literals; no runtime global or
  source-call rewrite is needed.
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
  rows". `list.set_index` and `list.set` now have matching host and target
  signatures; the cleaner naming is deferred to a coordinated change above.
  Historical `string.chars`/`lower` callers remain under the separate
  source-migration plan.
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
