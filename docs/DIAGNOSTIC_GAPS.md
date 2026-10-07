# Diagnostic Gaps

Open diagnostic-quality findings. Add a minimal input, actual message, desired
help/location and raising owner when a weak diagnostic is encountered. Delete
closed entries; regression fixtures and Git preserve completed work. Numbers
are stable and never reused. Cost S means wording/help; M means a rule, lookup
or recovery point; L means a cross-cutting data change. Priority reflects how
frequently newcomers encounter the mistake and how much the message helps.

Start with [Worker Checklist](WORKER_CHECKLIST.md). Discovery owns lex/parse
messages (`compiler_new/stage_01_discovery/{lex,parse,diagnostics}`); semantic
messages belong to `compiler/stage_06_typecheck`. Find a fixed output phrase
with `rg -n -F '<phrase>' blorp/src`, then cite its raising site. Source line
numbers below are survey pointers and may drift.

The original survey used a FRESH source-checkout compiler at `d460bac5f` on
2026-10-02 and `bin/blorp check --no-format` on otherwise valid programs.
Unless stated otherwise, excerpts below are survey evidence, not a current
reproduction. On FRESH main `3f1632c19579ea9b6e1af0cceaedc76e34a671ea`,
2026-10-03 checks still accept `Int[]`, triple-quoted strings and duplicate
functions/parameters; `Strng` is now rejected as an unknown type. Near-name
suggestions remain open under DG-017.

## Compiler faults (CF)

Wrong acceptance, internal errors, invalid C and wrong results. They are not
message-wording tasks.

| ID | Open fault |
| --- | --- |
| CF-001 | Bare print emits an undeclared wrapper |
| CF-004 | Unknown uppercase pattern binds silently |
| CF-005 | Int[] silently becomes Int |
| CF-006 | Triple-quoted string becomes empty |
| CF-007 | Duplicate functions and parameters accepted |
| CF-009 | Pure function reads mutable module var (design decision open) |
| CF-010 | Generic impls lose trait defaults; operators compare pointers |
| CF-011 | Record literal fields reordered after ownership |

## High ROI

### DG-001 Semantic errors carry no source location

- Input:
  ```
  pure func double(x: Int) -> Int:
      return x * 2
  ```
- Current output:
  ```
  error: Unbound value `return`
  ```
  Parse errors in the same tool print `file.brp:4:10: error: ...`. The few semantic errors that have a position append it to the end of the message (`... argument 2 expected Int, got String at ty_arg_type_mismatch.brp:5:12`). An error in an imported module names neither the file nor the module (`error: Function 'helper' returns wrong type` for a fault in `./helper.brp`).
- Should say: `file.brp:2:5: error: ...` for every error, the same shape as parse errors, with the module path when it is not the root file.
- Owner: stage_06_typecheck. `infer.brp:6186 infer_error` stores `typecheck_diagnostic(message, None)`; 205 call sites in `infer.brp` use it against 6 that supply a location through `infer_error_at` (and 3 located `typecheck_state_add_error_at` calls in `decl.brp`). `TypecheckDiagnostic` already has a `span: Option[SourceLocation]` and the CLI prints only the message text.
- Priority/cost: High / L (every `infer_error` site needs a span, or the inference context must carry the current node's span)

### DG-002 One bad expression cascades into two or three more errors

- Input:
  ```
  func main(args: List[String]) -> Int:
      frobnicate(1)
  ```
- Current output:
  ```
  error: Unbound value `frobnicate`
  error: Cannot call non-function type: Void
  error: Function 'main' returns wrong type
      expected: Int  (declared return type)
         found: Void  (body expression)
  ```
  The same happens for every unbound name, wrong-arity call, unknown method, failed `?=` and mismatched `if` branch: the failed expression is typed `Void` and the `Void` is then reported as a mismatch where it is used.
- Should say: only the first error. A failed expression needs an error type that unifies with everything and reports nothing.
- Owner: stage_06_typecheck, `infer.brp:7765` (typed `TYPE_VOID` after the error); follow-ups at `infer.brp:11118` and `decl.brp:4212`.
- Priority/cost: High / M

### DG-003 `return` is an unbound name with no explanation

- Input:
  ```
  pure func clamp(x: Int) -> Int:
      if x > 10:
          return 10
      x
  ```
- Current output:
  ```
  error: Unbound value `return`
  error: if-expression without else cannot produce a value; then-branch returns Int
  ```
  In a lambda, `func(x): return x` instead gives `expected `)` after call arguments` and two `expected expression` errors.
- Should say: "Blorp has no `return`: the last expression of a block is its value. For an early exit use `if`/`else` or `match`; use `?=` to propagate a `None` or `Err`."
- Owner: stage_06_typecheck `infer.brp:7765`; lambda case in `render.brp`.
- Priority/cost: High / S

### DG-004 Names from other languages are unbound with no hint

- Input, each in an otherwise valid body: `ok: Bool = true`, `x: Option[Int] = null`, `for i in range(10):`, `len(xs)`, `str(x)`, `int("5")`, `pass`, `const x = 5`, `let x = 5`, `p: P = new P(1)`, `assert 1 == 1`, `yield 1`, `exit(1)`, `await f()`, `Error("a")`.
- Current output (all alike):
  ```
  error: Unbound value `true`
  error: Binding `ok` declared as `Bool` but initializer has type `Void`
  ```
  `range(10)` and `len(xs)` add `Cannot call non-function type: Void`. `let mut x = 5` adds `Unbound value `mut``.
- Should say: a known-habit table on the unbound-name path: `true`/`false` -> `True`/`False`; `null`/`undefined`/`nil`/`Nothing` -> `None`; `range(n)` -> `0..n`; `len(x)` -> `x.length()`; `str(x)` -> `to_string(x)`; `int(s)` -> `s.parse_int()` (returns an Option); `pass` -> `void`; `const`/`let` -> a plain binding `x = 5`, with `var` for mutable; `new T(..)` -> the literal `{ field = value }`; `Error(e)` -> `Err(e)`.
- Owner: stage_06_typecheck `infer.brp:7765` (one lookup before reporting).
- Priority/cost: High / S (a table of about 20 entries) with DG-002 removing the noise

### DG-005 A method call on an unknown function says "Cannot access field"

- Input: `o.unwrap()`, `xs.push(2)`, `xs.fitler(f)`, `x.frobnicate()`, `s.length`, `x.to_str()`, `"a{}".format(1)`, `xs.sorted()`, `d.items()`
- Current output:
  ```
  error: Cannot access field on type Option[Int]. Field access is supported on record fields. Use tuple[index] for tuple elements
  error: Cannot call non-function type: Void
  error: Function 'main' returns wrong type
  ```
  Nothing names the method, and the user wrote a call, not a field.
- Should say: "No function or method `unwrap` for `Option[Int]`", a did-you-mean against the functions whose first parameter is that type (for example `unwrap` -> `get_or(default)` or `match`; `push` -> `append`, which returns a new list; `s.length` -> `s.length()`), and the field-access wording only when the name is not called.
- Owner: stage_06_typecheck `infer.brp:16236`.
- Priority/cost: High / M

### DG-006 A discarded result silently does nothing: `xs.append(1)`

- Input:
  ```
  var xs: List[Int] = []
  xs.append(1)
  print("len ${xs.length()}")
  ```
- Current output: `Type checking succeeded.` and the program prints `len 0`. `bin/blorp lint` reports nothing. The same holds for `d.set(k, v)`, `s.upper()`, `xs.reverse()` and a bare `double(3)`.
- Should say: a warning (or error) for an expression statement of a pure call whose non-`Void` result is unused: "`append` returns a new list; the result is unused. Write `xs = xs.append(1)`, or `_ = ...` to discard it on purpose."
- Owner: none yet; typecheck of expression statements in `stage_06_typecheck`, or a rule in `blorp/src/lint/`.
- Priority/cost: High / M

### DG-007 `def`, `fn`, `function`, `class`, `pub`, `impl` at top level print a cascade

- Input: `def double(x: Int) -> Int:` (also `fn double(x: Int) -> Int:`, `function double(x: Int): Int {`, `class Counter:`, `pub func f() -> Int:`, `export func`, `async func`, `impl Counter {`, `interface P {`, `mod m {`, `use std::x;`, `from list import map`, `if __name__ == "__main__":`)
- Current output (`def`):
  ```
  py_def.brp:1:5: error: expected `=` after top-level variable declaration
  help: write `=` between the name and its value
  py_def.brp:1:13: error: expected `)` after call arguments
  help: close the parenthesis opened earlier with `)`
  py_def.brp:1:13: error: expected declaration
  ```
  9 errors for `def`, 9 for `fn`, 13 for `function`, 6 for `class` and `pub`, 19 for `use`. None mention that the keyword is wrong.
- Should say: on the first token of a top-level item: "`def` is not a Blorp keyword; declare a function with `func name(x: Int) -> Int:`". Same for `fn`, `function`, `class` (use `record`), `impl` (use `implements Trait for Type:`), `pub` (declarations are public by default; use `private`), `export`, `use` (use `import:`). Then resynchronise so only one error is printed.
- Owner: discovery parser. `parse/declaration_parser.brp:434` raises `expected declaration` for every leftover token and `:498` raises `expected =` after a top-level variable; text in `diagnostics/render.brp:728` and `:1248`.
- Priority/cost: High / M (keyword table S; resynchronisation M, shared with DG-008)

### DG-008 Parser reports a cascade of follow-on errors after the first

- Input: any block-header mistake, for example `if a && b:`, `elif x > 3:`, `for (var i = 0; i < 3; i++):`, `enum Color = Red | Green`
- Current output: the first error is usually right, then 5 to 20 more:
  ```
  c_and_and.brp:4:10: error: unexpected character '&'
  c_and_and.brp:4:11: error: unexpected character '&'
  c_and_and.brp:4:13: error: expected `:` after if condition
  c_and_and.brp:4:13: error: expected newline before indented block
  c_and_and.brp:4:13: error: expected an indented block
  ... 7 more, ending in `expected declaration` for each later line
  ```
  12 errors for `&&`, 20 for the C-style `for`, 16 for `enum X = ...`.
- Should say: stop reporting once a block header has failed, or resynchronise at the next line whose indentation is at or below the header's, and report nothing inside the skipped region.
- Owner: discovery parser recovery: `parse/parser_cursor.brp` (recovery after a missing token) and `parse/block_layout.brp`; text in `diagnostics/render.brp`.
- Priority/cost: High / M

### DG-009 Lambda habits give `expected expression` and no teaching

- Input: `f = lambda x: x + 1`, `xs.map(x => x + 1)`, `xs.map((x) => x + 1)`, `xs.map(|x| x + 1)`
- Current output:
  ```
  py_lambda.brp:2:17: error: expected expression
  help: write a value, a name or a call here
  ```
  The arrow forms give `expected `)` after call arguments` and two `expected expression` errors; the Rust form gives five.
- Should say: "Blorp lambdas are written `func(x): x + 1` (`pure func(x): ...` for a pure one)." Trigger on a bare `lambda` name before a parameter, and on `=>` or `|` where an expression is expected inside call arguments.
- Owner: discovery parser, `parse/expression_atoms.brp:143` (`expected expression`) and the lambda parse in `parse/body_parser.brp`; text in `diagnostics/render.brp:1301`.
- Priority/cost: High / S to M

### DG-010 f-strings and template strings

- Input: `print(f"hello {name}")`, ``print(`hello ${name}`)``
- Current output:
  ```
  py_fstring.brp:3:12: error: expected `)` after call arguments
  help: close the parenthesis opened earlier with `)`
  py_fstring.brp:3:26: error: expected expression
  ```
  and for backticks `unexpected character '`'` twice plus `unexpected character '$'`.
- Should say: "Blorp has no f-strings or template strings; put `${expr}` inside an ordinary double-quoted string: `"hello ${name}"`." Trigger on an identifier `f` (or a backtick) immediately followed by a string.
- Owner: discovery lexer `lex/lexer.brp` (`UnexpectedCharacterDiagnostic`) and `lex/string_literals.brp`; text in `diagnostics/render.brp:458`.
- Priority/cost: High / S

### DG-011 Import errors lack suggestions and attempted paths

- Input: `lst: map`, `no_such_module: foo`, `./nothere: foo`, `list: mapp`, `option: Option(Some, Nope)`
- Current output:
  ```
  error: Could not find module 'lst'
  error: 'mapp' is not exported by module 'list'
  error: constructor 'Nope' is not exported by type 'Option' from module 'option'
  ```
  Unknown modules now name the missing path at the import location, but do not suggest a near match. A missing relative file does not show the path tried. Missing symbols also have no near-match suggestion.
- Should say: "cannot find module `lst`; did you mean `list`?" while retaining the import line's position; for a missing symbol, list close names from the module (`mapp` -> `map`); for a missing relative file, the path that was tried.
- Owner: `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp` (missing modules and imported symbols).
- Priority/cost: High / M (edit distance over a module's exports)

### DG-012 A typo'd constructor in a pattern is a silent catch-all

- Moved to CF-004: a wrong acceptance that also breaks exhaustiveness checking and, on a `Result`, the backend.

### DG-013 Assigning to an immutable binding gives no way forward

- Input:
  ```
  x: Int = 1
  x = 2
  ```
  (also `x += 2`, a parameter, and `let mut x = 5` then `x = 6`)
- Current output: `error: Cannot assign to immutable variable 'x'`
- Should say: add "declare it with `var x: Int = 1` to make it mutable; for a parameter, bind a new name".
- Owner: stage_06_typecheck `infer.brp:20907` and `:20939`.
- Priority/cost: High / S

### DG-014 Python tuple loops: `for i, x in ...`

- Input: `for i, x in enumerate(xs):`, `for k, v in d.items():`, `for a, b in pairs:`, `for x of xs:`, `for (x in xs):`
- Current output:
  ```
  x_enumerate.brp:3:10: error: expected `in` after for loop variable
  help: a keyword is missing or misspelled: `in` follows a loop variable, `from` follows a select receive binding and `func` starts a function
  ```
  then 11 to 14 more errors. `for (x in xs)` says `Tuples support 2-4 elements`. `for x of xs` gets the same generic `in` help.
- Should say: "a loop over pairs needs parentheses: `for (i, x) in xs.enumerate():`; iterate a `Dict` directly with `for (k, v) in d`" (`entries()` also exists).
- Owner: discovery parser, `parse/body_parser.brp:1177` (`expect_keyword_token(InKeyword, ...)`); text in `diagnostics/render.brp:791` and `:1490` (the generic keyword help is shared by `for`, `select`, `implements` and `type`).
- Priority/cost: High / S

### DG-015 Indexing: `xs[0]`, `s[0]`, `args[1]`, `d["k"]`, `xs[0] = v`

- Input: `xs: List[Int] = [1, 2, 3]` then `xs[0]`
- Current output:
  ```
  error: checked_get is not supported on List. Use get(list, index) for bounds-checked access
  error: Function 'main' returns wrong type
  ```
  `s[0]` says the same for String; `d["a"]` gives `Subscript index must be Int, got String` and `checked_get requires an array type, got Dict[String, Int]`; `xs[0] = 5` gives `Type List[Int] does not support subscript assignment. Subscript assignment is supported on array types`; `d["a"] = 1` prints three errors, the first claiming the immutable binding is the problem.
- Should say: "lists are read with `xs.get(0)`, which returns an `Option` (`xs.get(0).get_or(0)`); update with `xs = xs.set(0, 5)`", and "dicts: `d.get("a")` and `d.set("a", 1)`". Drop `checked_get`, an internal name, from user text.
- Owner: stage_06_typecheck `infer.brp:17008` and `:16422`.
- Priority/cost: High / S

### DG-016 Record construction habits

- Input: `p: P = P(1, 2)`, `Point { x = 1, y = 2 }`, `Point { x: 1, y: 2 }`, `{x: 1, y: 2}`, `new P(1)`
- Current output:
  ```
  error: Unbound value `P`
  error: Cannot call non-function type: Void
  error: Binding `p` declared as `P` but initializer has type `Void`
  ```
  The braces forms give `expected `}` after vector literal` (the word "vector" is wrong), or `Unbound value `Point``.
- Should say: "a record is built with a literal and the type is inferred from the annotation: `p: P = {x = 1, y = 2}`; `P` is a type, not a function". For `:` inside braces: "fields use `=`".
- Owner: typecheck `infer.brp:7765` (`Unbound value`); discovery parser `parse/body_parser.brp:2256` (`RightBraceInVectorLiteral`), text in `diagnostics/render.brp:708`.
- Priority/cost: High / S to M

### DG-017 Rust and TS primitive type names

- Input: `x: i32`, `u32`, `f64`, `bool`, `string`, `str`, `number`
- Current output: `error: Unknown type 'i32' while resolving 'f'` (`u32` is reported twice).
- Should say: "unknown type `i32`; did you mean `Int32`?" with a table: `i8..i64`/`u8..u64` -> `Int8`..`UInt64`, `f32`/`f64` -> `Float32`/`Float`, `bool` -> `Bool`, `string`/`str` -> `String`, `number` -> `Int` or `Float`, `char` -> `Char`, `Integer` -> `Int`, `Vec<T>` -> `List[T]`; an unknown near-name such as `Strng` -> `String` remains an independent suggestion improvement. Current `Strng` help asks for explicit generic brackets or spelling/import checks; it does not suggest `String`.
- Owner: `stage_06_typecheck/headers/type_header_graph.brp:3861`.
- Priority/cost: High / S

### DG-018 Unknown capitalised type names

The wrong acceptance is closed: `Strng` is rejected. Near-name help belongs to DG-017; CF-005 now owns only the `Int[]` parser fault.

### DG-019 `Option` or `Result` used where the plain value is expected

- Input: `n: Int = xs.get(0)`, `n: Int = d.get("a")`, `n: Int = "5".parse_int()`, `x: Int = f()` where `f` returns `Result`, `o + 1`, `s: String = input("x")`
- Current output:
  ```
  error: Binding `n` declared as `Int` but initializer has type `Option[Int]`
  error: Cannot apply + to Option[Int] and Int
  ```
- Should say: add "this can fail, so it returns an `Option`; unwrap with `.get_or(default)`, `match`, or `?=` in a function that returns `Option`". `get_or` is named in the guide and exists on `Option` and `Result`.
- Owner: stage_06_typecheck `infer.brp:21033` (binding), `:6491` (operators).
- Priority/cost: High / S

### DG-020 `"n=" + n`, `Int + Float`, `"ab" * 3`

- Input: `print("n=" + n)`, `z: Float = x + y` with `Int` and `Float`, `"ab" * 3`, `"a%d" % 1`, `y: Int = x` with `x: Float`
- Current output:
  ```
  error: Cannot apply + to String and Int
  error: Type Void does not implement trait Stringable (required by print)
  ```
  The `+` case adds a cascade line; `Float` to `Int` says only ``declared as `Int` but initializer has type `Float` ``.
- Should say: "`+` joins two Strings; write `"n=${n}"` or `n.to_string()`"; "`Int + Float` needs one side converted: `x.to_float() + y`"; "`*` does not repeat strings; use `"ab".repeat(3)`"; `Float` to `Int`: `y.to_int()`.
- Owner: stage_06_typecheck `infer.brp:6491`, `:6516`, `:6547`.
- Priority/cost: High / S

### DG-021 `elif`, `elseif`, `else` after a loop

- Input: `elif x > 3:`, `elseif x > 1:`, `else:` after `for` or `while`
- Current output (`elif`):
  ```
  py_elif.brp:5:15: error: expected expression
  help: write a value, a name or a call here
  py_elif.brp:6:9: error: expected expression
  ... 8 more, including: `else` is a reserved keyword and cannot be used as a name
  ```
- Should say: "write `else if x > 3:`". For a loop `else`: "`for` and `while` have no `else` block".
- Owner: discovery parser, `parse/expression_atoms.brp:143`; the later `else` complaint is `parse/parser_cursor.brp:611` (`ReservedKeywordAsName`).
- Priority/cost: High / S

### DG-022 Comments: `#`, `//`, `/* */`

- Input: `# note`, `x = 1 // note`, `/* note */`
- Current output: `py_hash_comment.brp:2:5: error: expected expression` with `help: write a value, a name or a call here`
- Should say: "comments start with `--`" (also `///` and `/* */` have no equivalent; use `--` lines).
- Owner: discovery lexer `lex/lexer.brp`, then `parse/expression_atoms.brp:143`.
- Priority/cost: High / S

### DG-023 Operator habits: `||`, `in`, `not in`, `is`, `===`, `!==`, `**`, `//`, `++`

- Input: `if a || b:`, `if 3 in xs:`, `if 3 not in xs:`, `if x is None:`, `x === 1`, `2 ** 3`, `7 // 2`, `i++`
- Current output: `||` gives `expected `:` after if condition` plus 11 more errors, with no hint, while `&&` and `!` do get one. `in`, `not in`, `is`, `===`, `**`, `//` and `++` print `expected expression`, or the `if` header cascade (`in`: 11 errors, `is`: 10, `===`: 11).
- Should say: `||` -> `or`; `x in xs` -> `xs.contains(x)`; `not in` -> `not xs.contains(x)`; `is None` -> `x.is_none()` or `match`; `===`/`!==` -> `==`/`!=`; `**` -> `x.pow(y)` (`Float`); `//` -> `/` (`Int` division already truncates) or the comment hint in DG-022; `i++` -> `i += 1`.
- Owner: discovery lexer `lex/lexer.brp` (`&&` and `!` help exists; `||` falls through), `parse/body_parser.brp:954` for the `if` header; text in `diagnostics/render.brp:458`.
- Priority/cost: High / S

### DG-024 Keyword and default arguments

- Input: `greet(name = "x")`, `print("a", end = "")`, `func greet(name: String = "x")`
- Current output:
  ```
  py_kwargs_call.brp:5:16: error: an assignment is a statement, not an expression
  help: assign on its own line first, then use the name where the value is needed
  ```
  A default parameter gives `expected `)` after function parameters` and about seven follow-ups.
- Should say: "Blorp has no named or default arguments; pass the value positionally, and use `Option` or a record for optional settings".
- Owner: discovery parser, `parse/body_parser.brp:851` (`AssignmentInExpressionDiagnostic`) and `parse/binder_parser.brp:111` for a default parameter; text in `diagnostics/render.brp:1336`.
- Priority/cost: High / S

### DG-025 `?` and `&` and `!` help text is wrong

- Input: `x = parse(s)?`, `p?.x`, `f(&xs)`, `xs: &List[Int]`, `vec![1, 2]`, `println!("hi")`
- Current output:
  ```
  rs_question_op.brp:5:17: error: unexpected character '?'
  help: remove it, or put it inside a string literal if it is text
  rs_ampersand_arg.brp:6:10: error: unexpected character '&'
  help: Blorp writes boolean operators as words: use `and`, `or` and `not`
  rs_vec_macro.brp:2:24: error: unexpected character '!'
  help: Blorp writes boolean negation as `not`, and inequality as `!=`
  ```
- Should say: `?` -> "there is no postfix `?`; bind with `x ?= parse(s)`"; `&x` -> "Blorp has no references; values are passed by value"; `name!(...)` -> "no macros; use `print(...)` and a list literal `[1, 2]`".
- Owner: discovery lexer `lex/lexer.brp` (`UnexpectedCharacterDiagnostic`); the help texts are in `diagnostics/render.brp:458` to `:462`.
- Priority/cost: High / S

### DG-026 `self`, methods and `impl` blocks

- Input: `func bump(self) -> Int:`, `impl Counter {`, `fn bump(self) -> Int {`
- Current output: `error: callable 'bump' parameter 1 must have an explicit type` and the `impl` forms give the DG-007 cascade.
- Should say: "Blorp has no `self`; a method is a function whose first parameter has the type: `func bump(c: Counter) -> Int:`, called as `c.bump()`".
- Owner: `stage_06_typecheck/headers/callable_headers.brp:998`.
- Priority/cost: High / S

---

## Medium ROI

### DG-030 Match arms: guards, `case`, `=>`

- Input: `Some(x) if x > 0: x`, `Some(x) when x > 0: x`, `case Some(x): x`, `Some(x) => x`
- Current output: `expected `:` after match pattern` with the generic block help, then up to 7 more errors.
- Should say: "match arms have no guards; test inside the arm with `if`", and "arms are `Pattern: result`, with no `case` and no `=>`".
- Owner: discovery parser, `parse/body_parser.brp:1052` (`ColonInMatchPattern`); text in `diagnostics/render.brp:546`.
- Priority/cost: Medium / S

### DG-031 Block braces and one-line bodies

- Input: `if (x > 0) {`, `match o {`, `func f(x: Int) -> Int {`, `func f(x: Int): Int:`, `if x > 0: print("a")`
- Current output: `expected `:` after if condition` / `expected newline before indented block` / `expected an indented block`, then a cascade (DG-008).
- Should say: "Blorp blocks use a trailing `:` and indentation, not braces; put the body on its own indented lines". For `: Int` return types: "the return type follows `->`".
- Owner: discovery parser, `parse/body_parser.brp:954` and `parse/block_layout.brp:67` to `:74`; text in `diagnostics/render.brp:546` and `:770`.
- Priority/cost: Medium / S

### DG-032 Unclosed bracket points at the next line

- Input:
  ```
  func main(args: List[String]) -> Int:
      f(1
      0
  ```
- Current output: `x_unclosed_paren_call.brp:6:5: error: expected `)` after call arguments` with `help: close the parenthesis opened earlier with `)``. The position is the next line's first token, and the opener is never located. Same for `[`, `{` and an extra `)`/`]`, which prints `expected expression`.
- Should say: report the position of the unclosed `(`: "`(` opened here is never closed" plus the position where the parser gave up.
- Owner: discovery parser, the delimiter expectations in `parse/body_parser.brp` (for example `:1990`, `ExpectedRightParen`) and `parse/parser_cursor.brp`; text in `diagnostics/render.brp:1458`.
- Priority/cost: Medium / M (the parser needs a stack of open delimiters)

### DG-033 Over-indented line and a few reserved-word cases point at the wrong place

- Input:
  ```
  func main(args: List[String]) -> Int:
      x: Int = 1
        y: Int = 2
      x
  ```
- Current output:
  ```
  bl_odd_indent.brp:3:1: error: expected declaration
  help: start a function declaration with `func`
  bl_odd_indent.brp:4:5: error: expected declaration
  help: start a function declaration with `func`
  bl_odd_indent.brp:5:1: error: expected `=` after top-level variable declaration
  help: write `=` between the name and its value
  bl_odd_indent.brp:5:1: error: expected expression
  help: write a value, a name or a call here
  bl_odd_indent.brp:5:1: error: expected declaration
  help: start a function declaration with `func`
  ```
  The file has 4 lines; the first error names column 1 of the right line, not the indent, and the last is past the end. `select: Int = 1` (a keyword used as a name) reports `4:1` in a 3-line file.
- Should say: `3:7: error: unexpected indentation; this line is indented deeper than the block it follows`.
- Owner: discovery layout, `lex/layout.brp:401`: the `IndentToken` span starts at the line start (`indent_start`), so the first error reports column 1. The parser then has no stray-indent diagnostic: `parse/declaration_parser.brp:434` leaves the function body and reports every following line as a top-level `expected declaration`. The between-levels dedent case is `lex/layout.brp:416` and `diagnostics/render.brp:1136`.
- Priority/cost: Medium / S to M

### DG-034 Missing `:` on a function header produces no `:` message

- Input: `func f(x: Int) Int:`, `func f x: Int -> Int:`, `func f(x Int) -> Int:`, `func f(Int x) -> Int:`, `func -> Int double(x: Int):`. (The colon missing at the end of a line, `func main(args: List[String]) -> Int` with an indented body, now reports ``expected `:` before function body`` at the end of the header and reads the body.)
- Current output (`func f(x: Int) Int:`): several errors, ``error: expected declaration`` / ``help: start a function declaration with `func` ``. `if`, `for`, `while`, `match` and `else` handle the same slip well.
- Should say: ``expected `:` after the function header`` at the end of the signature, as the other block headers do; for `x Int`, "write `x: Int`".
- Owner: discovery parser, `parse/body_parser.brp:417` (`ColonInFunctionBody`, the non-newline case) and `parse/binder_parser.brp:111`; text in `diagnostics/render.brp:531`.
- Priority/cost: Medium / S

### DG-035 `"{name}"` and `"$name"` print the braces or the dollar sign

- Input: `print("hello {name}")`, `print("hello $name")`
- Current output: `Type checking succeeded.` Both print the text literally. The Guide documents the brace case ("Literal braces work without escaping"), so this is quiet wrong output, not a bug. (`"""hello"""` silently being the empty string is a fault: see CF-006.)
- Should say: a lint finding "did you mean `${name}`?" when a hole-like `{name}` or `$name` matches a local binding.
- Owner: `blorp/src/lint/`.
- Priority/cost: Medium / M

### DG-036 Duplicate definitions are accepted

- Moved to CF-007: a wrong acceptance; the later definition silently wins.

### DG-037 Generic bound syntax

- Input: `func f[T: Orderable, Stringable](a: T) -> T:`, `func f<T: Orderable>(a: T)`, `-> T where T: Orderable:`, `[T: Orderable & Stringable]`
- Current output: the comma form is accepted and silently declares a second type parameter named `Stringable` (see GUIDE: multiple bounds use `+`). The others cascade: `<T: ...>` 16 errors, `where` 11 errors that talk about dimension constraints (`expected dimension name or literal after `#``), `&` 14 errors.
- Should say: "multiple bounds are joined with `+`: `[T: Orderable + Stringable]`"; "type parameters use square brackets, not `<>`"; "bounds are written inline; there is no `where`". Warn when a bound name in a type-parameter list is a trait, because it is surely meant as a bound.
- Owner: discovery parser (`parse/function_parser.brp`, `parse/type_parser.brp`) for the syntax forms; old typecheck headers for the silent case.
- Priority/cost: Medium / S

### DG-038 Lists and Dicts: comprehensions, slices, dict literals, tuple fields

- Input: `[x * 2 for x in xs]`, `xs[1:2]`, `{"a": 1}`, `t.0`, `[...a, 2]`, `[0..3]`, `a, b = (1, 2)`
- Current output: `[x * 2 for x in xs]` gives `expected `]` after list literal` and an `expected `:` after for loop iterable` cascade. `{"a": 1}` gives `expected `}` after vector literal`. `t.0` gives `expected field name`. `[...a, 2]` and `a, b = (1, 2)` give `expected expression`. `[0..3]` gives `List element 1 expected Int, got Range`.
- Should say: comprehension -> `.map` and `.filter`; slice -> `xs.drop(1).take(1)`; dict literal -> `{"a" => 1}` (the form is in GUIDE section 3); `t.0` -> `t[0]`; spread -> `a + [2]`; unparenthesised unpack -> `(a, b) = (1, 2)`; `[0..3]` -> `(0..3).to_list()`.
- Owner: discovery parser, `parse/body_parser.brp:2256`, `parse/expression_atoms.brp:128` (`NameInFieldName`); text in `diagnostics/render.brp:499` and `:708`; typecheck for the `Range` element.
- Priority/cost: Medium / S each, M for the set

### DG-039 Unimported module alias or receiver blames arity

- Input: `math.sqrt(4.0)` and `console.log("hi")` with `math` not imported
- Current output:
  ```
  error: Function 'sqrt' expects 1 argument, got 2
  error: Function 'log' expects 1 argument, got 2
  ```
  The receiver is treated as the first UFCS argument, so the real problem (no `math` in scope) is never mentioned.
- Should say: "`math` is not defined; import it with `import:` / `math as math`" for a known std module; "`console` is not defined" otherwise.
- Owner: stage_06_typecheck `infer.brp:9649`, `:9702` (module alias paths) and the UFCS fallback.
- Priority/cost: Medium / M

### DG-040 Generic-callback and arity messages are jargon without signatures

- Input: `o.get_or("a")` for `Option[Int]`, `xs.map(func(a): a + 1)` bound to `List[String]`, `xs.map(func(a, b): a)`, `add(1)` for `add(a: Int, b: Int)`
- Current output:
  ```
  error: Generic type parameter T inferred as Int and String
  error: Generic type parameter U inferred as Int and String
  error: Cannot infer type of lambda parameter `b`; add a type annotation
  error: Function 'add' expects 2 arguments, got 1
  ```
- Should say: name the argument and the function: "`get_or` expects a default of type `Int`, got `String`"; for a callback of the wrong arity "`map` expects a function of 1 argument, got one of 2"; for arity, show the signature `add(a: Int, b: Int) -> Int`.
- Owner: stage_06_typecheck `infer.brp:8841`, `:14212`.
- Priority/cost: Medium / M

### DG-041 A missing trait implementation gives no way forward

- Input: `print(p)` for `record P`, `if p == q:` for a record, a call of `biggest(p, p)` with `T: Orderable`
- Current output:
  ```
  error: Type P does not implement trait Stringable (required by print)
  error: Type P does not implement trait Orderable (required by biggest)
  ```
- Should say: add the skeleton: "write `implements Stringable for P:` with `pure func to_string(p: P) -> String:`" (interpolation `"${p}"` does not need it for built-in types; say so).
- Owner: stage_06_typecheck `infer.brp:10015` (already has a `help` slot).
- Priority/cost: Medium / S

### DG-042 Reserved words used as names: second error and `select`

- Input: `type: Int = 1` then `type`, same for `from`, `in`, `alias`, `resource`, `where`
- Current output:
  ```
  x_kw_as_name_type.brp:2:5: error: `type` is a reserved keyword and cannot be used as a name
  help: choose another identifier such as `type_name`
  x_kw_as_name_type.brp:3:5: error: expected expression
  help: write a value, a name or a call here
  ```
  The first error is good; each later use adds an `expected expression`. `select` prints three errors at `4:1` past the end of the file.
- Should say: only the first error, and accept the rejected name for the rest of the scope. (`on`, `after` and `with` as names are accepted; `on` as a use is `expected expression`.)
- Owner: discovery parser, `parse/parser_cursor.brp:611` (`ReservedKeywordAsName`); text in `diagnostics/render.brp:873`.
- Priority/cost: Medium / S

### DG-043 `try`, `except`, `with open`, `import x from y`, `from x import y`, `import list`

- Input: `try:` / `except:`, `with open("f") as f:`, `import x from y`
- Current output: `try` prints ten errors starting `expected expression`; `with open(...)` gives `expected `=` or `?=` after with binding` and ``type ascription with `as` was removed``; `import list` gives a good first error (``expected `:` after import`` with the `import:` hint) and three follow-ups; `from list import map` is a DG-007 cascade.
- Should say: for `try`/`except`: "Blorp has no exceptions; fallible functions return `Result` or `Option`; propagate with `?=` or handle with `match`".
- Owner: discovery parser, `parse/body_parser.brp` (statement and `with` forms), `parse/import_parser.brp`; text in `diagnostics/render.brp`.
- Priority/cost: Medium / S

### DG-044 Inclusive ranges, chained comparisons and valueless declarations

- Input: `for i in 0..=3:` (inclusive), `if 0 < x < 3:`, `x: Int` with no value, `var x: Int` then `x = 1`
- Current output: `..=` prints 15 errors; the chained comparison says `Comparison requires matching types that implement Orderable, got Bool and Int`; a declaration with no value says `expected expression` at the colon; `var x: Int` prints three errors starting at the next line.
- Should say: ranges are exclusive and `..=` does not exist (use `0..4`); chained comparison -> `0 < x and x < 3`; "every binding needs a value; write `x: Int = 0`".
- Owner: discovery parser, `parse/expression_atoms.brp:143`; typecheck `infer.brp:6589`.
- Priority/cost: Medium / S each

### DG-046 A typo in an assignment target creates a new binding

- Input:
  ```
  var total: Int = 0
  totl = 5
  total
  ```
- Current output: `Type checking succeeded.` `totl` becomes a fresh immutable binding that nothing reads. `var x: Int = 1` that is never mutated and unused bindings are also silent.
- Should say: a lint (not an error, since `x = 5` is the declaration form) for a binding that is never read, with a did-you-mean for a near-matching `var`.
- Owner: `blorp/src/lint/`.
- Priority/cost: Medium / M

---

## Low ROI

### DG-050 Explicit generic call syntax

- Input: `f<Int>(1)`, `f[Int](1)`
- Current output: `error: `Int` is not a value`, then comparison and subscript errors (`Comparison requires matching types ... got (T) -> T and Void`).
- Should say: "type arguments are inferred; annotate the binding instead: `x: Int = f(1)`".
- Owner: stage_06_typecheck `infer.brp`.
- Priority/cost: Low / S

### DG-051 Declaration shapes `Int x = 1` and `f(Int x)`

- Input: `Int x = 1`, `func f(Int x) -> Int:`
- Current output: ``error: `Int` is not a value``; `expected `)` after function parameters` plus a cascade.
- Should say: "write the name first: `x: Int = 1`".
- Owner: discovery parser `parse/binder_parser.brp`; typecheck `infer.brp`.
- Priority/cost: Low / S

### DG-052 `if x:` on a non-Bool has no help

- Input: `if x:` with `x: Int`
- Current output: `If condition must be Bool, got Int`
- Should say: add "compare explicitly, `x != 0`". (A `pure func` reading a mutable module `var` is accepted: a purity question filed as CF-009.)
- Owner: stage_06_typecheck `infer.brp`.
- Priority/cost: Low / S
