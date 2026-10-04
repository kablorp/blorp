# Diagnostic Gaps

A living ledger of places where the compiler's diagnostics fall short of what a
first-time user, or an agent that has never seen Blorp, needs in order to fix
their program. Blorp is in no model's training data, so people write Python,
Rust and JavaScript habits first, and the diagnostic is the only teacher they
get. [`AGENTS.md`](../AGENTS.md) rule 6 requires every error to carry a help
suggestion; rule 7 asks what a Python, JS or Rust programmer would try first and
requires that it either work or produce a helpful message.

**Anyone who meets a weak diagnostic adds an entry here**, whether a person or
an agent, in the same change or in a docs-only change of its own. When a gap is
fixed, delete its entry and move a one-line note to "Checked and good" with the
regression fixture that protects it. Do not leave fixed entries behind.

Two kinds of entry live here:

- **DG** entries are diagnostic quality: the compiler correctly rejects (or
  correctly accepts) the program, and the message, location or help is weak.
- **CF** entries are compiler faults found while probing: a wrong acceptance, an
  internal error, invalid generated C, or a wrong result. A fault is not a
  wording problem, so it is filed as a document in
  [`docs/issues/`](issues/) (title, `Status: open`, repro, evidence, proposed fix,
  owner) and the ledger keeps a short entry that points at it. If a DG entry turns
  out to be a fault, move it to a CF entry and leave a one-line cross-reference
  under its old number.

The front end is the discovery stage,
`blorp/src/compiler_new/stage_01_discovery/` (lexer in `lex/`, parser in
`parse/`, error text in `diagnostics/render.brp`); `compiler/stage_02_lex` and
`stage_03_parse` serve only the formatter, the LSP, `blorp test` discovery and
`compile --ast`. Type checking is the old
`blorp/src/compiler/stage_06_typecheck/`, which the rewrite replaces.

**How to find the owner of a message.** Take a fixed phrase from the output and
`grep -rn --include=*.brp -F "<phrase>" blorp/src`. A parse or lex message is a
row in `diagnostics/render.brp`: take the diagnostic constructor named just above
the phrase (for example `ColonInIfCondition`) and grep `lex/` and `parse/` for it to
find where it is raised. A bare `error: ...` with no position is a typecheck message
in `stage_06_typecheck/`. Cite the raising site, not only the render table.

## Index

One line per entry. Fault entries (CF) first, then diagnostic entries (DG) by tier.

| ID | Title | Tier | Cost |
|---|---|---|---|
| CF-001 | A bare `print` statement passes `check` and emits invalid C | Fault | M |
| CF-004 | An uppercase pattern name that is not a constructor binds silently | Fault | M |
| CF-005 | `Int[]` silently becomes `Int`; unknown type names generalise | Fault | S |
| CF-006 | `"""hello"""` is silently the empty string | Fault | S |
| CF-007 | Duplicate function and parameter names are accepted | Fault | S |
| CF-009 | A `pure func` may read a module-level `var` (design question open) | Fault | S |
| DG-001 | Semantic errors carry no source location | High | L |
| DG-002 | One bad expression cascades into two or three more errors | High | M |
| DG-003 | `return` is an unbound name with no explanation | High | S |
| DG-004 | Names from other languages are unbound with no hint | High | S |
| DG-005 | A method call on an unknown function says "Cannot access field" | High | M |
| DG-006 | A discarded result silently does nothing: `xs.append(1)` | High | M |
| DG-007 | `def`, `fn`, `function`, `class`, `pub`, `impl` at top level print a cascade | High | M |
| DG-008 | Parser reports a cascade of follow-on errors after the first | High | M |
| DG-009 | Lambda habits give `expected expression` and no teaching | High | S |
| DG-010 | f-strings and template strings | High | S |
| DG-011 | Import errors lack suggestions and attempted paths | High | M |
| DG-012 | A typo'd constructor in a pattern is a silent catch-all | moved to CF-004 | - |
| DG-013 | Assigning to an immutable binding gives no way forward | High | S |
| DG-014 | Python tuple loops: `for i, x in ...` | High | S |
| DG-015 | Indexing: `xs[0]`, `s[0]`, `args[1]`, `d["k"]`, `xs[0] = v` | High | S |
| DG-016 | Record construction habits | High | S |
| DG-017 | Rust and TS primitive type names | High | S |
| DG-018 | An unknown capitalised type name silently becomes a type parameter | moved to CF-005 | - |
| DG-019 | `Option` or `Result` used where the plain value is expected | High | S |
| DG-020 | `"n=" + n`, `Int + Float`, `"ab" * 3` | High | S |
| DG-021 | `elif`, `elseif`, `else` after a loop | High | S |
| DG-022 | Comments: `#`, `//`, `/* */` | High | S |
| DG-023 | Operator habits: `\|\|`, `in`, `not in`, `is`, `===`, `!==`, `**`, `//`, `++` | High | S |
| DG-024 | Keyword and default arguments | High | S |
| DG-025 | `?` and `&` and `!` help text is wrong | High | S |
| DG-026 | `self`, methods and `impl` blocks | High | S |
| DG-030 | Match arms: guards, `case`, `=>` | Medium | S |
| DG-031 | Block braces and one-line bodies | Medium | S |
| DG-032 | Unclosed bracket points at the next line | Medium | M |
| DG-033 | Over-indented line and a few reserved-word cases point at the wrong place | Medium | S |
| DG-034 | Missing `:` on a function header produces no `:` message | Medium | S |
| DG-035 | `"{name}"` and `"$name"` print the braces or the dollar sign | Medium | M |
| DG-036 | Duplicate definitions are accepted | moved to CF-007 | - |
| DG-037 | Generic bound syntax | Medium | S |
| DG-038 | Lists and Dicts: comprehensions, slices, dict literals, tuple fields | Medium | S |
| DG-039 | Unimported module alias or receiver blames arity | Medium | M |
| DG-040 | Generic-callback and arity messages are jargon without signatures | Medium | M |
| DG-041 | A missing trait implementation gives no way forward | Medium | S |
| DG-042 | Reserved words used as names: second error and `select` | Medium | S |
| DG-043 | `try`, `except`, `with open`, `import x from y`, `from x import y`, `import list` | Medium | S |
| DG-044 | Inclusive ranges, chained comparisons and valueless declarations | Medium | S |
| DG-046 | A typo in an assignment target creates a new binding | Medium | M |
| DG-050 | Explicit generic call syntax | Low | S |
| DG-051 | Declaration shapes `Int x = 1` and `f(Int x)` | Low | S |
| DG-052 | `if x:` on a non-Bool has no help | Low | S |

## Entry format

```
### DG-NNN Short title
- Input: the minimal snippet (the rest of the program is valid)
- Current output: an exact excerpt of `bin/blorp check --no-format`
- Should say: what the message and help line ought to teach
- Owner: stage and source file, as found by a quick grep
- Cost: S, M or L
- ROI: High, Medium or Low, with the reason
```

- **Cost** is for the fix, not the investigation. S is one message or help
  string. M is a new rule, a lookup table, or a parser resynchronisation point
  in one stage. L is cross-cutting: many call sites, or a new data model.
- **ROI** is how often people will hit it times how much a better message
  helps. A mistake every newcomer makes on day one that currently prints
  nothing useful is High even when the fix is small.
- Numbers are stable: never reuse or renumber. A new entry takes the next free
  number in its tier's range (001-029 High, 030-049 Medium, 050 and up Low);
  if its ROI is later re-judged, move the entry, keep the number. Within a tier
  the order is rough priority.
- Fixes are one-line proposals only. The ledger is not a design document.
- CF entries use the same fields as DG, with "Should be" in place of "Should say",
  and an "Issue" line naming the file in `docs/issues/`. CF numbers are in their
  own sequence, never reused.

How an entry is judged: does it point at the right place, does it say what is
wrong in the user's terms, does it carry a help line that teaches the correct
form, and does an earlier error cascade into noise.

## Survey provenance

First survey: 2026-10-02 against `d460bac5f`, a source-checkout `bin/blorp`
built with `make`, every probe run as `bin/blorp check --no-format file.brp`.
421 single-mistake probe programs (each an otherwise valid program with one
plausible Python, Rust, JS/TS or Blorp-specific mistake) plus 10 follow-up
runs with `bin/blorp run`, `compile` and `lint`. Counts: 38 were valid
programs that were correctly accepted, 115 diagnostics were good, 268 fell
short in a way recorded below. DG-001 and DG-002 are systemic and are not
counted against every individual probe they touch: of the 115 good ones, most
still lack a source location because of DG-001. The 268 "short" probes include
those that revealed the seven CF entries below.

Two sources emit diagnostics. Parse and lexical errors are rendered by
`blorp/src/compiler_new/stage_01_discovery/diagnostics/render.brp`
(`file:line:col: error:` plus a `help:` line). Semantic errors are written by the
typecheck stage, mostly `blorp/src/compiler/stage_06_typecheck/infer.brp`, and
print as a bare `error: message` with no `help:` line unless the message embeds
one.

---

## Compiler faults (CF)

Faults found while probing. Each is filed in [`docs/issues/`](issues/) and is not
a message-wording problem. Wrong-location bugs (DG-032, DG-033) stay diagnostics.
Parse and lex faults belong to the discovery stage, which is the default front
end; typecheck faults belong to the old `compiler/stage_06_typecheck`, which the
rewrite replaces, so prefer a fix that the replacement can carry over.

### CF-001 A bare `print` statement passes `check` and emits invalid C
- Input:
  ```
  func main(args: List[String]) -> Int:
      print
      0
  ```
  (also the Python 2 habit `print "hello"`, read as the statements `print` and
  `"hello"`)
- Current output: `check` prints `Type checking succeeded.`; `bin/blorp run` prints
  `C compiler exited with status 1: <stdin>:230:19: error: use of undeclared
  identifier '__ufcs_io__print'`.
- Should be: a typecheck error for an expression statement that names a function
  without calling it, or Core declaring what it releases.
- Owner: typecheck (old stage_06) for the diagnostic; Core lowering
  `compiler/stage_08_core_lower/lower.brp:871` for the undeclared wrapper.
- Cost: M
- Issue: [`print-statement-emits-undeclared-ufcs-wrapper.md`](issues/print-statement-emits-undeclared-ufcs-wrapper.md)


### CF-004 An uppercase pattern name that is not a constructor binds silently
- Input:
  ```
  match o:
      Some(x): x
      Nothing: 7
  ```
  with `o: Option[Int]`; also `red:` for a variant `Red`, and `_: 0` before `1: 1`.
- Current output: `Type checking succeeded.`; `run` takes the `Nothing` arm as a
  catch-all. On a `Result` scrutinee, `Ok(x): x` with `None: 7` or `Nothing: 7`
  passes `check` with no `Err` arm required and `run` fails with `#error "Blorp backend
  could not emit function body: $blorp$user_main_120"`.
- Should be: ``error: `Nothing` is not a constructor of `Option[Int]` `` listing its
  constructors; a did-you-mean for a case-insensitive match; an unreachable-arm
  warning.
- Owner: typecheck pattern inference, `compiler/stage_06_typecheck/infer.brp:18767`.
- Cost: M
- Issue: [`unknown-uppercase-pattern-name-binds-silently.md`](issues/unknown-uppercase-pattern-name-binds-silently.md)

### CF-005 `Int[]` silently becomes `Int`; unknown type names generalise
- Input: `func f(x: Int[]) -> Int:` then `f([1, 2])`; and `func f(x: Strng) -> Int:`
- Current output: both declarations pass. The call fails with `argument 1
  expected Int, got List[Int]`. `x: Integer = 1` says ``declared as `Integer` but
  initializer has type `Int` `` and never that `Integer` is unknown.
- Should be: `[]` after a type is an error ("write `List[Int]`"). A near miss such
  as `Strng` should be an unknown-type error suggesting `String`. The owner decided
  on 2026-10-02 to remove unbounded auto-generalisation, so type parameters must be
  declared. The parser-rejection work (branch `syntax/reject-typecheck-only-forms`)
  removes it, which turns `Strng` into an unknown name.
- Owner: discovery `parse/type_parser.brp` for `[]`; old typecheck
  `headers/type_header_graph.brp` for unknown names.
- Cost: S for `[]`; M for near misses
- Issue: [`int-array-suffix-type-becomes-int.md`](issues/int-array-suffix-type-becomes-int.md)

### CF-006 `"""hello"""` is silently the empty string
- Input: `s: String = """hello"""` then `print("[${s}]")`
- Current output: `check` succeeds; `run` prints `[]`.
- Should be: an error; Blorp has no triple-quoted strings (use `|` aligned
  multiline strings).
- Owner: discovery lexer `lex/string_literals.brp` and statement parser
  `parse/body_parser.brp` (two expressions on one line).
- Cost: S
- Issue: [`triple-quoted-string-lexes-as-empty-string.md`](issues/triple-quoted-string-lexes-as-empty-string.md)

### CF-007 Duplicate function and parameter names are accepted
- Input: two `func f() -> Int:` declarations (bodies `1` and `2`), or
  `func f(a: Int, a: Int) -> Int:`
- Current output: `Type checking succeeded.`; `run` prints `2`, the later definition.
- Should be: ``function `f` is already defined at file.brp:1:1`` and
  ``parameter `a` is declared twice``.
- Owner: `compiler/stage_06_typecheck/headers/callable_headers.brp:990` (the
  duplicate type-parameter check is the model).
- Cost: S
- Issue: [`duplicate-function-and-parameter-accepted.md`](issues/duplicate-function-and-parameter-accepted.md)

### CF-009 A `pure func` may read a module-level `var` (design question open)
- Input: `var counter: Int = 0` and `pure func f() -> Int:` returning `counter`
- Current output: `check` succeeds; `run` prints `0`. Assigning to the `var` in a pure
  function is rejected; reading it is not.
- Should be: the owner decides. Reject the read ("pass it as a parameter") or
  document that reads are allowed; principle 4 favours rejecting.
- Owner: purity checks, `compiler/stage_06_typecheck/decl.brp:4401`.
- Cost: S
- Issue: [`pure-function-reads-mutable-module-var.md`](issues/pure-function-reads-mutable-module-var.md)

---

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
  Parse errors in the same tool print `file.brp:4:10: error: ...`. The few
  semantic errors that have a position append it to the end of the message
  (`... argument 2 expected Int, got String at ty_arg_type_mismatch.brp:5:12`).
  An error in an imported module names neither the file nor the module (`error:
  Function 'helper' returns wrong type` for a fault in `./helper.brp`).
- Should say: `file.brp:2:5: error: ...` for every error, the same shape as
  parse errors, with the module path when it is not the root file.
- Owner: stage_06_typecheck. `infer.brp:6186 infer_error` stores
  `typecheck_diagnostic(message, None)`; 205 call sites in `infer.brp` use it
  against 6 that supply a location through `infer_error_at` (and 3 located
  `typecheck_state_add_error_at` calls in `decl.brp`). `TypecheckDiagnostic` already has a
  `span: Option[SourceLocation]` and the CLI prints only the message text.
- Cost: L (every `infer_error` site needs a span, or the inference context must
  carry the current node's span)
- ROI: High. Nearly every semantic error hits it, and an agent editing a
  30-line file cannot tell which of two similar lines failed.

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
  The same happens for every unbound name, wrong-arity call, unknown method,
  failed `?=` and mismatched `if` branch: the failed expression is typed `Void`
  and the `Void` is then reported as a mismatch where it is used.
- Should say: only the first error. A failed expression needs an error type that
  unifies with everything and reports nothing.
- Owner: stage_06_typecheck, `infer.brp:7765` (typed `TYPE_VOID` after the
  error); follow-ups at `infer.brp:11118` and `decl.brp:4212`.
- Cost: M
- ROI: High. Every semantic mistake is affected; the follow-ups bury the real
  error and double or triple an agent's reading cost.

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
  In a lambda, `func(x): return x` instead gives `expected `)` after call
  arguments` and two `expected expression` errors.
- Should say: "Blorp has no `return`: the last expression of a block is its
  value. For an early exit use `if`/`else` or `match`; use `?=` to propagate a
  `None` or `Err`."
- Owner: stage_06_typecheck `infer.brp:7765`; lambda case in `render.brp`.
- Cost: S
- ROI: High. The first thing Python, Rust, JS, Go and C programmers type.

### DG-004 Names from other languages are unbound with no hint
- Input, each in an otherwise valid body: `ok: Bool = true`,
  `x: Option[Int] = null`, `for i in range(10):`, `len(xs)`, `str(x)`,
  `int("5")`, `pass`, `const x = 5`, `let x = 5`, `p: P = new P(1)`,
  `assert 1 == 1`, `yield 1`, `exit(1)`, `await f()`, `Error("a")`.
- Current output (all alike):
  ```
  error: Unbound value `true`
  error: Binding `ok` declared as `Bool` but initializer has type `Void`
  ```
  `range(10)` and `len(xs)` add `Cannot call non-function type: Void`.
  `let mut x = 5` adds `Unbound value `mut``.
- Should say: a known-habit table on the unbound-name path: `true`/`false` ->
  `True`/`False`; `null`/`undefined`/`nil`/`Nothing` -> `None`; `range(n)` ->
  `0..n`; `len(x)` -> `x.length()`; `str(x)` -> `to_string(x)`;
  `int(s)` -> `s.parse_int()` (returns an Option); `pass` -> `void`;
  `const`/`let` -> a plain binding `x = 5`, with `var` for mutable;
  `new T(..)` -> the literal `{ field = value }`; `Error(e)` -> `Err(e)`.
- Owner: stage_06_typecheck `infer.brp:7765` (one lookup before reporting).
- Cost: S (a table of about 20 entries) with DG-002 removing the noise
- ROI: High. These are the most common first programs an agent writes.

### DG-005 A method call on an unknown function says "Cannot access field"
- Input: `o.unwrap()`, `xs.push(2)`, `xs.fitler(f)`, `x.frobnicate()`,
  `s.length`, `x.to_str()`, `"a{}".format(1)`, `xs.sorted()`, `d.items()`
- Current output:
  ```
  error: Cannot access field on type Option[Int]. Field access is supported on record fields. Use tuple[index] for tuple elements
  error: Cannot call non-function type: Void
  error: Function 'main' returns wrong type
  ```
  Nothing names the method, and the user wrote a call, not a field.
- Should say: "No function or method `unwrap` for `Option[Int]`", a did-you-mean
  against the functions whose first parameter is that type (for example
  `unwrap` -> `get_or(default)` or `match`; `push` -> `append`, which returns a
  new list; `s.length` -> `s.length()`), and the field-access wording only when the name is not called.
- Owner: stage_06_typecheck `infer.brp:16236`.
- Cost: M
- ROI: High. UFCS is the language's main composition mechanism and the method
  name is the most likely thing to be wrong.

### DG-006 A discarded result silently does nothing: `xs.append(1)`
- Input:
  ```
  var xs: List[Int] = []
  xs.append(1)
  print("len ${xs.length()}")
  ```
- Current output: `Type checking succeeded.` and the program prints `len 0`.
  `bin/blorp lint` reports nothing. The same holds for `d.set(k, v)`,
  `s.upper()`, `xs.reverse()` and a bare `double(3)`.
- Should say: a warning (or error) for an expression statement of a pure call
  whose non-`Void` result is unused: "`append` returns a new list; the result is
  unused. Write `xs = xs.append(1)`, or `_ = ...` to discard it on purpose."
- Owner: none yet; typecheck of expression statements in `stage_06_typecheck`,
  or a rule in `blorp/src/lint/`.
- Cost: M
- ROI: High. The Python and JS habit for mutation; it compiles, runs, and gives
  wrong output with no signal at all.

### DG-007 `def`, `fn`, `function`, `class`, `pub`, `impl` at top level print a cascade
- Input: `def double(x: Int) -> Int:` (also `fn double(x: Int) -> Int:`,
  `function double(x: Int): Int {`, `class Counter:`, `pub func f() -> Int:`,
  `export func`, `async func`, `impl Counter {`, `interface P {`, `mod m {`,
  `use std::x;`, `from list import map`, `if __name__ == "__main__":`)
- Current output (`def`):
  ```
  py_def.brp:1:5: error: expected `=` after top-level variable declaration
  help: write `=` between the name and its value
  py_def.brp:1:13: error: expected `)` after call arguments
  help: close the parenthesis opened earlier with `)`
  py_def.brp:1:13: error: expected declaration
  ```
  9 errors for `def`, 9 for `fn`, 13 for `function`, 6 for `class` and `pub`,
  19 for `use`. None mention that the keyword is wrong.
- Should say: on the first token of a top-level item: "`def` is not a Blorp
  keyword; declare a function with `func name(x: Int) -> Int:`". Same for `fn`,
  `function`, `class` (use `record`), `impl` (use `implements Trait for Type:`),
  `pub` (declarations are public by default; use `private`), `export`, `use`
  (use `import:`). Then resynchronise so only one error is printed.
- Owner: discovery parser. `parse/declaration_parser.brp:434` raises `expected
  declaration` for every leftover token and `:498` raises `expected =` after a
  top-level variable; text in `diagnostics/render.brp:728` and `:1248`.
- Cost: M (keyword table S; resynchronisation M, shared with DG-008)
- ROI: High. The very first line of a Python, Rust or JS port.

### DG-008 Parser reports a cascade of follow-on errors after the first
- Input: any block-header mistake, for example `if a && b:`, `elif x > 3:`,
  `for (var i = 0; i < 3; i++):`, `enum Color = Red | Green`
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
- Should say: stop reporting once a block header has failed, or resynchronise at
  the next line whose indentation is at or below the header's, and report
  nothing inside the skipped region.
- Owner: discovery parser recovery: `parse/parser_cursor.brp` (recovery after a
  missing token) and `parse/block_layout.brp`; text in `diagnostics/render.brp`.
- Cost: M
- ROI: High. Every syntax mistake; it multiplies tokens read and hides which
  line was the real fault.

### DG-009 Lambda habits give `expected expression` and no teaching
- Input: `f = lambda x: x + 1`, `xs.map(x => x + 1)`, `xs.map((x) => x + 1)`,
  `xs.map(|x| x + 1)`
- Current output:
  ```
  py_lambda.brp:2:17: error: expected expression
  help: write a value, a name or a call here
  ```
  The arrow forms give `expected `)` after call arguments` and two
  `expected expression` errors; the Rust form gives five.
- Should say: "Blorp lambdas are written `func(x): x + 1` (`pure func(x): ...`
  for a pure one)." Trigger on a bare `lambda` name before a parameter, and on
  `=>` or `|` where an expression is expected inside call arguments.
- Owner: discovery parser, `parse/expression_atoms.brp:143` (`expected expression`)
  and the lambda parse in `parse/body_parser.brp`; text in `diagnostics/render.brp:1301`.
- Cost: S to M
- ROI: High. Callbacks to `map`/`filter` are in nearly every program.

### DG-010 f-strings and template strings
- Input: `print(f"hello {name}")`, ``print(`hello ${name}`)``
- Current output:
  ```
  py_fstring.brp:3:12: error: expected `)` after call arguments
  help: close the parenthesis opened earlier with `)`
  py_fstring.brp:3:26: error: expected expression
  ```
  and for backticks `unexpected character '`'` twice plus `unexpected character '$'`.
- Should say: "Blorp has no f-strings or template strings; put `${expr}` inside an
  ordinary double-quoted string: `"hello ${name}"`." Trigger on an identifier
  `f` (or a backtick) immediately followed by a string.
- Owner: discovery lexer `lex/lexer.brp` (`UnexpectedCharacterDiagnostic`) and
  `lex/string_literals.brp`; text in `diagnostics/render.brp:458`.
- Cost: S
- ROI: High. Every Python port uses f-strings.

### DG-011 Import errors lack suggestions and attempted paths
- Input: `lst: map`, `no_such_module: foo`, `./nothere: foo`, `list: mapp`,
  `option: Option(Some, Nope)`
- Current output:
  ```
  error: Could not find module 'lst'
  error: 'mapp' is not exported by module 'list'
  error: constructor 'Nope' is not exported by type 'Option' from module 'option'
  ```
  Unknown modules now name the missing path at the import location, but do not
  suggest a near match. A missing relative file does not show the path tried.
  Missing symbols also have no near-match suggestion.
- Should say: "cannot find module `lst`; did you mean `list`?" while retaining
  the import line's position; for a missing symbol, list close names from the module
  (`mapp` -> `map`); for a missing relative file, the path that was tried.
- Owner: `blorp/src/compiler/stage_06_typecheck/modules/module_binding.brp`
  (missing modules and imported symbols).
- Cost: M (edit distance over a module's exports)
- ROI: High. Agents hallucinate standard-library names constantly and the error
  tells them nothing about what exists.

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
- Should say: add "declare it with `var x: Int = 1` to make it mutable; for a
  parameter, bind a new name".
- Owner: stage_06_typecheck `infer.brp:20907` and `:20939`.
- Cost: S
- ROI: High. Day-one mistake for anyone writing a loop accumulator.

### DG-014 Python tuple loops: `for i, x in ...`
- Input: `for i, x in enumerate(xs):`, `for k, v in d.items():`,
  `for a, b in pairs:`, `for x of xs:`, `for (x in xs):`
- Current output:
  ```
  x_enumerate.brp:3:10: error: expected `in` after for loop variable
  help: a keyword is missing or misspelled: `in` follows a loop variable, `from` follows a select receive binding and `func` starts a function
  ```
  then 11 to 14 more errors. `for (x in xs)` says `Tuples support 2-4 elements`.
  `for x of xs` gets the same generic `in` help.
- Should say: "a loop over pairs needs parentheses: `for (i, x) in xs.enumerate():`;
  iterate a `Dict` directly with `for (k, v) in d`" (`entries()` also exists).
- Owner: discovery parser, `parse/body_parser.brp:1177`
  (`expect_keyword_token(InKeyword, ...)`); text in `diagnostics/render.brp:791` and
  `:1490` (the generic keyword help is shared by `for`, `select`, `implements` and
  `type`).
- Cost: S
- ROI: High. Extremely common Python loop shape, plus a misleading help line.

### DG-015 Indexing: `xs[0]`, `s[0]`, `args[1]`, `d["k"]`, `xs[0] = v`
- Input: `xs: List[Int] = [1, 2, 3]` then `xs[0]`
- Current output:
  ```
  error: checked_get is not supported on List. Use get(list, index) for bounds-checked access
  error: Function 'main' returns wrong type
  ```
  `s[0]` says the same for String; `d["a"]` gives `Subscript index must be Int,
  got String` and `checked_get requires an array type, got Dict[String, Int]`;
  `xs[0] = 5` gives `Type List[Int] does not support subscript assignment.
  Subscript assignment is supported on array types`; `d["a"] = 1` prints three
  errors, the first claiming the immutable binding is the problem.
- Should say: "lists are read with `xs.get(0)`, which returns an `Option`
  (`xs.get(0).get_or(0)`); update with `xs = xs.set(0, 5)`", and "dicts: `d.get("a")`
  and `d.set("a", 1)`". Drop `checked_get`, an internal name, from user text.
- Owner: stage_06_typecheck `infer.brp:17008` and `:16422`.
- Cost: S
- ROI: High. Indexing is among the first five operations anyone tries.

### DG-016 Record construction habits
- Input: `p: P = P(1, 2)`, `Point { x = 1, y = 2 }`, `Point { x: 1, y: 2 }`,
  `{x: 1, y: 2}`, `new P(1)`
- Current output:
  ```
  error: Unbound value `P`
  error: Cannot call non-function type: Void
  error: Binding `p` declared as `P` but initializer has type `Void`
  ```
  The braces forms give `expected `}` after vector literal` (the word "vector"
  is wrong), or `Unbound value `Point``.
- Should say: "a record is built with a literal and the type is inferred from the
  annotation: `p: P = {x = 1, y = 2}`; `P` is a type, not a function". For `:`
  inside braces: "fields use `=`".
- Owner: typecheck `infer.brp:7765` (`Unbound value`); discovery parser
  `parse/body_parser.brp:2256` (`RightBraceInVectorLiteral`), text in
  `diagnostics/render.brp:708`.
- Cost: S to M
- ROI: High. Building a value of a user type is the second thing after a
  function.

### DG-017 Rust and TS primitive type names
- Input: `x: i32`, `u32`, `f64`, `bool`, `string`, `str`, `number`
- Current output: `error: Unknown type 'i32' while resolving 'f'`
  (`u32` is reported twice).
- Should say: "unknown type `i32`; did you mean `Int32`?" with a table:
  `i8..i64`/`u8..u64` -> `Int8`..`UInt64`, `f32`/`f64` -> `Float32`/`Float`,
  `bool` -> `Bool`, `string`/`str` -> `String`, `number` -> `Int` or `Float`,
  `char` -> `Char`, `Integer` -> `Int`, `Vec<T>` -> `List[T]`.
- Owner: `stage_06_typecheck/headers/type_header_graph.brp:3861`.
- Cost: S
- ROI: High. Every Rust and TS signature.

### DG-018 An unknown capitalised type name silently becomes a type parameter
- Moved to CF-005: `Int[]` silently becoming `Int` and `Strng` becoming a type parameter are both faults; removing unbounded auto-generalisation fixes the second.

### DG-019 `Option` or `Result` used where the plain value is expected
- Input: `n: Int = xs.get(0)`, `n: Int = d.get("a")`, `n: Int = "5".parse_int()`,
  `x: Int = f()` where `f` returns `Result`, `o + 1`, `s: String = input("x")`
- Current output:
  ```
  error: Binding `n` declared as `Int` but initializer has type `Option[Int]`
  error: Cannot apply + to Option[Int] and Int
  ```
- Should say: add "this can fail, so it returns an `Option`; unwrap with
  `.get_or(default)`, `match`, or `?=` in a function that returns `Option`".
  `get_or` is named in the guide and exists on `Option` and `Result`.
- Owner: stage_06_typecheck `infer.brp:21033` (binding), `:6491` (operators).
- Cost: S
- ROI: High. Any fallible std call; the type is shown but the next step is not.

### DG-020 `"n=" + n`, `Int + Float`, `"ab" * 3`
- Input: `print("n=" + n)`, `z: Float = x + y` with `Int` and `Float`,
  `"ab" * 3`, `"a%d" % 1`, `y: Int = x` with `x: Float`
- Current output:
  ```
  error: Cannot apply + to String and Int
  error: Type Void does not implement trait Stringable (required by print)
  ```
  The `+` case adds a cascade line; `Float` to `Int` says only
  ``declared as `Int` but initializer has type `Float` ``.
- Should say: "`+` joins two Strings; write `"n=${n}"` or `n.to_string()`";
  "`Int + Float` needs one side converted: `x.to_float() + y`"; "`*` does not
  repeat strings; use `"ab".repeat(3)`"; `Float` to `Int`: `y.to_int()`.
- Owner: stage_06_typecheck `infer.brp:6491`, `:6516`, `:6547`.
- Cost: S
- ROI: High. Mixed arithmetic and string building are everywhere.

### DG-021 `elif`, `elseif`, `else` after a loop
- Input: `elif x > 3:`, `elseif x > 1:`, `else:` after `for` or `while`
- Current output (`elif`):
  ```
  py_elif.brp:5:15: error: expected expression
  help: write a value, a name or a call here
  py_elif.brp:6:9: error: expected expression
  ... 8 more, including: `else` is a reserved keyword and cannot be used as a name
  ```
- Should say: "write `else if x > 3:`". For a loop `else`: "`for` and `while` have
  no `else` block".
- Owner: discovery parser, `parse/expression_atoms.brp:143`; the later `else`
  complaint is `parse/parser_cursor.brp:611` (`ReservedKeywordAsName`).
- Cost: S
- ROI: High. Common, and the output ends up complaining about `else`.

### DG-022 Comments: `#`, `//`, `/* */`
- Input: `# note`, `x = 1 // note`, `/* note */`
- Current output: `py_hash_comment.brp:2:5: error: expected expression` with
  `help: write a value, a name or a call here`
- Should say: "comments start with `--`" (also `///` and `/* */` have no
  equivalent; use `--` lines).
- Owner: discovery lexer `lex/lexer.brp`, then `parse/expression_atoms.brp:143`.
- Cost: S
- ROI: High. Unmissable first mistake; the help is generic.

### DG-023 Operator habits: `||`, `in`, `not in`, `is`, `===`, `!==`, `**`, `//`, `++`
- Input: `if a || b:`, `if 3 in xs:`, `if 3 not in xs:`, `if x is None:`,
  `x === 1`, `2 ** 3`, `7 // 2`, `i++`
- Current output: `||` gives `expected `:` after if condition` plus 11 more
  errors, with no hint, while `&&` and `!` do get one. `in`, `not in`, `is`,
  `===`, `**`, `//` and `++` print `expected expression`, or the `if` header
  cascade (`in`: 11 errors, `is`: 10, `===`: 11).
- Should say: `||` -> `or`; `x in xs` -> `xs.contains(x)`; `not in` ->
  `not xs.contains(x)`; `is None` -> `x.is_none()` or `match`; `===`/`!==` ->
  `==`/`!=`; `**` -> `x.pow(y)` (`Float`); `//` -> `/` (`Int` division
  already truncates) or the comment hint in DG-022; `i++` -> `i += 1`.
- Owner: discovery lexer `lex/lexer.brp` (`&&` and `!` help exists; `||` falls
  through), `parse/body_parser.brp:954` for the `if` header; text in
  `diagnostics/render.brp:458`.
- Cost: S
- ROI: High. Collectively very common; `||` alone is the obvious omission.

### DG-024 Keyword and default arguments
- Input: `greet(name = "x")`, `print("a", end = "")`, `func greet(name: String = "x")`
- Current output:
  ```
  py_kwargs_call.brp:5:16: error: an assignment is a statement, not an expression
  help: assign on its own line first, then use the name where the value is needed
  ```
  A default parameter gives `expected `)` after function parameters` and about
  seven follow-ups.
- Should say: "Blorp has no named or default arguments; pass the value
  positionally, and use `Option` or a record for optional settings".
- Owner: discovery parser, `parse/body_parser.brp:851`
  (`AssignmentInExpressionDiagnostic`) and `parse/binder_parser.brp:111` for a default
  parameter; text in `diagnostics/render.brp:1336`.
- Cost: S
- ROI: High. Agents reach for keyword arguments on any multi-parameter call, and
  the current help sends them down the wrong path.

### DG-025 `?` and `&` and `!` help text is wrong
- Input: `x = parse(s)?`, `p?.x`, `f(&xs)`, `xs: &List[Int]`, `vec![1, 2]`,
  `println!("hi")`
- Current output:
  ```
  rs_question_op.brp:5:17: error: unexpected character '?'
  help: remove it, or put it inside a string literal if it is text
  rs_ampersand_arg.brp:6:10: error: unexpected character '&'
  help: Blorp writes boolean operators as words: use `and`, `or` and `not`
  rs_vec_macro.brp:2:24: error: unexpected character '!'
  help: Blorp writes boolean negation as `not`, and inequality as `!=`
  ```
- Should say: `?` -> "there is no postfix `?`; bind with `x ?= parse(s)`"; `&x` ->
  "Blorp has no references; values are passed by value"; `name!(...)`
  -> "no macros; use `print(...)` and a list literal `[1, 2]`".
- Owner: discovery lexer `lex/lexer.brp` (`UnexpectedCharacterDiagnostic`); the
  help texts are in `diagnostics/render.brp:458` to `:462`.
- Cost: S
- ROI: High. `?` is the Rust error idiom, and `&` gets an actively wrong hint.

### DG-026 `self`, methods and `impl` blocks
- Input: `func bump(self) -> Int:`, `impl Counter {`, `fn bump(self) -> Int {`
- Current output: `error: callable 'bump' parameter 1 must have an explicit type`
  and the `impl` forms give the DG-007 cascade.
- Should say: "Blorp has no `self`; a method is a function whose first parameter
  has the type: `func bump(c: Counter) -> Int:`, called as `c.bump()`".
- Owner: `stage_06_typecheck/headers/callable_headers.brp:998`.
- Cost: S
- ROI: High. Object-oriented habit in Python and Rust.

---

## Medium ROI

### DG-030 Match arms: guards, `case`, `=>`
- Input: `Some(x) if x > 0: x`, `Some(x) when x > 0: x`, `case Some(x): x`,
  `Some(x) => x`
- Current output: `expected `:` after match pattern` with the generic block
  help, then up to 7 more errors.
- Should say: "match arms have no guards; test inside the arm with `if`", and
  "arms are `Pattern: result`, with no `case` and no `=>`".
- Owner: discovery parser, `parse/body_parser.brp:1052` (`ColonInMatchPattern`);
  text in `diagnostics/render.brp:546`.
- Cost: S
- ROI: Medium. Guards are an ordinary thing to want.

### DG-031 Block braces and one-line bodies
- Input: `if (x > 0) {`, `match o {`, `func f(x: Int) -> Int {`,
  `func f(x: Int): Int:`, `if x > 0: print("a")`
- Current output: `expected `:` after if condition` / `expected newline before
  indented block` / `expected an indented block`, then a cascade (DG-008).
- Should say: "Blorp blocks use a trailing `:` and indentation, not braces;
  put the body on its own indented lines". For `: Int` return types: "the return
  type follows `->`".
- Owner: discovery parser, `parse/body_parser.brp:954` and `parse/block_layout.brp:67`
  to `:74`; text in `diagnostics/render.brp:546` and `:770`.
- Cost: S
- ROI: Medium. Hits every brace-language port; the existing help text is close.

### DG-032 Unclosed bracket points at the next line
- Input:
  ```
  func main(args: List[String]) -> Int:
      f(1
      0
  ```
- Current output: `x_unclosed_paren_call.brp:6:5: error: expected `)` after call
  arguments` with `help: close the parenthesis opened earlier with `)``. The
  position is the next line's first token, and the opener is never located.
  Same for `[`, `{` and an extra `)`/`]`, which prints `expected expression`.
- Should say: report the position of the unclosed `(`: "`(` opened here is never
  closed" plus the position where the parser gave up.
- Owner: discovery parser, the delimiter expectations in `parse/body_parser.brp`
  (for example `:1990`, `ExpectedRightParen`) and `parse/parser_cursor.brp`; text in
  `diagnostics/render.brp:1458`.
- Cost: M (the parser needs a stack of open delimiters)
- ROI: Medium. Location-quality bug that costs real time on long calls.

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
  The file has 4 lines; the first error names column 1 of the right line, not the
  indent, and the last is past the end. `select: Int = 1` (a keyword used as a
  name) reports `4:1` in a 3-line file.
- Should say: `3:7: error: unexpected indentation; this line is indented deeper
  than the block it follows`.
- Owner: discovery layout, `lex/layout.brp:401`: the `IndentToken` span starts at
  the line start (`indent_start`), so the first error reports column 1. The parser then
  has no stray-indent diagnostic: `parse/declaration_parser.brp:434` leaves the function
  body and reports every following line as a top-level `expected declaration`.
  The between-levels dedent case is `lex/layout.brp:416` and `diagnostics/render.brp:1136`.
- Cost: S to M
- ROI: Medium. Wrong-location bug; indentation slips are common for new users
  and for agents editing in place.

### DG-034 Missing `:` on a function header produces no `:` message
- Input: `func f(x: Int) Int:`, `func f x: Int -> Int:`, `func f(x Int) -> Int:`,
  `func f(Int x) -> Int:`, `func -> Int double(x: Int):`. (The colon missing at the end
  of a line, `func main(args: List[String]) -> Int` with an indented body, now reports
  ``expected `:` before function body`` at the end of the header and reads the body.)
- Current output (`func f(x: Int) Int:`): several errors, ``error: expected declaration``
  / ``help: start a function declaration with `func` ``.
  `if`, `for`, `while`, `match` and `else` handle the same slip well.
- Should say: ``expected `:` after the function header`` at the end of the
  signature, as the other block headers do; for `x Int`, "write `x: Int`".
- Owner: discovery parser, `parse/body_parser.brp:417` (`ColonInFunctionBody`, the
  non-newline case) and `parse/binder_parser.brp:111`; text in `diagnostics/render.brp:531`.
- Cost: S
- ROI: Medium. Rarer than the `if` form, but the output hides the cause.

### DG-035 `"{name}"` and `"$name"` print the braces or the dollar sign
- Input: `print("hello {name}")`, `print("hello $name")`
- Current output: `Type checking succeeded.` Both print the text literally. The
  Guide documents the brace case ("Literal braces work without escaping"), so this
  is quiet wrong output, not a bug. (`"""hello"""` silently being the empty
  string is a fault: see CF-006.)
- Should say: a lint finding "did you mean `${name}`?" when a hole-like `{name}` or
  `$name` matches a local binding.
- Owner: `blorp/src/lint/`.
- Cost: M
- ROI: Medium. Python and shell habit; the output is wrong with no signal.

### DG-036 Duplicate definitions are accepted
- Moved to CF-007: a wrong acceptance; the later definition silently wins.

### DG-037 Generic bound syntax
- Input: `func f[T: Orderable, Stringable](a: T) -> T:`,
  `func f<T: Orderable>(a: T)`, `-> T where T: Orderable:`,
  `[T: Orderable & Stringable]`
- Current output: the comma form is accepted and silently declares a second
  type parameter named `Stringable` (see GUIDE: multiple bounds use `+`). The
  others cascade: `<T: ...>` 16 errors, `where` 11 errors that talk about
  dimension constraints (`expected dimension name or literal after `#``), `&` 14
  errors.
- Should say: "multiple bounds are joined with `+`: `[T: Orderable + Stringable]`";
  "type parameters use square brackets, not `<>`"; "bounds are written inline;
  there is no `where`". Warn when a bound name in a type-parameter list is a
  trait, because it is surely meant as a bound.
- Owner: discovery parser (`parse/function_parser.brp`, `parse/type_parser.brp`) for
  the syntax forms; old typecheck headers for the silent case.
- Cost: S
- ROI: Medium. Bounded generics are a normal need; the silent one hides a bug.

### DG-038 Lists and Dicts: comprehensions, slices, dict literals, tuple fields
- Input: `[x * 2 for x in xs]`, `xs[1:2]`, `{"a": 1}`, `t.0`, `[...a, 2]`, `[0..3]`,
  `a, b = (1, 2)`
- Current output: `[x * 2 for x in xs]` gives `expected `]` after list literal`
  and an `expected `:` after for loop iterable` cascade. `{"a": 1}` gives
  `expected `}` after vector literal`. `t.0` gives `expected field name`.
  `[...a, 2]` and `a, b = (1, 2)` give `expected expression`. `[0..3]` gives
  `List element 1 expected Int, got Range`.
- Should say: comprehension -> `.map` and `.filter`; slice -> `xs.drop(1).take(1)`; dict literal -> `{"a" => 1}` (the form is in GUIDE section 3);
  `t.0` -> `t[0]`; spread -> `a + [2]`; unparenthesised unpack
  -> `(a, b) = (1, 2)`; `[0..3]` -> `(0..3).to_list()`.
- Owner: discovery parser, `parse/body_parser.brp:2256`, `parse/expression_atoms.brp:128`
  (`NameInFieldName`); text in `diagnostics/render.brp:499` and `:708`; typecheck for
  the `Range` element.
- Cost: S each, M for the set
- ROI: Medium. Each is a single Python or JS idiom; none is as common as the
  High entries.

### DG-039 Unimported module alias or receiver blames arity
- Input: `math.sqrt(4.0)` and `console.log("hi")` with `math` not imported
- Current output:
  ```
  error: Function 'sqrt' expects 1 argument, got 2
  error: Function 'log' expects 1 argument, got 2
  ```
  The receiver is treated as the first UFCS argument, so the real problem (no
  `math` in scope) is never mentioned.
- Should say: "`math` is not defined; import it with `import:` / `math as math`"
  for a known std module; "`console` is not defined" otherwise.
- Owner: stage_06_typecheck `infer.brp:9649`, `:9702` (module alias paths) and the
  UFCS fallback.
- Cost: M
- ROI: Medium. Wrong cause is worse than no message.

### DG-040 Generic-callback and arity messages are jargon without signatures
- Input: `o.get_or("a")` for `Option[Int]`, `xs.map(func(a): a + 1)` bound to
  `List[String]`, `xs.map(func(a, b): a)`, `add(1)` for `add(a: Int, b: Int)`
- Current output:
  ```
  error: Generic type parameter T inferred as Int and String
  error: Generic type parameter U inferred as Int and String
  error: Cannot infer type of lambda parameter `b`; add a type annotation
  error: Function 'add' expects 2 arguments, got 1
  ```
- Should say: name the argument and the function: "`get_or` expects a default
  of type `Int`, got `String`"; for a callback of the wrong arity "`map` expects a
  function of 1 argument, got one of 2"; for arity, show the signature
  `add(a: Int, b: Int) -> Int`.
- Owner: stage_06_typecheck `infer.brp:8841`, `:14212`.
- Cost: M
- ROI: Medium. These messages appear on every higher-order call that is wrong.

### DG-041 A missing trait implementation gives no way forward
- Input: `print(p)` for `record P`, `if p == q:` for a record, a call of
  `biggest(p, p)` with `T: Orderable`
- Current output:
  ```
  error: Type P does not implement trait Stringable (required by print)
  error: Type P does not implement trait Orderable (required by biggest)
  ```
- Should say: add the skeleton: "write
  `implements Stringable for P:` with `pure func to_string(p: P) -> String:`"
  (interpolation `"${p}"` does not need it for built-in types; say so).
- Owner: stage_06_typecheck `infer.brp:10015` (already has a `help` slot).
- Cost: S
- ROI: Medium. First hit when printing or comparing a user type.

### DG-042 Reserved words used as names: second error and `select`
- Input: `type: Int = 1` then `type`, same for `from`, `in`, `alias`, `resource`, `where`
- Current output:
  ```
  x_kw_as_name_type.brp:2:5: error: `type` is a reserved keyword and cannot be used as a name
  help: choose another identifier such as `type_name`
  x_kw_as_name_type.brp:3:5: error: expected expression
  help: write a value, a name or a call here
  ```
  The first error is good; each later use adds an `expected expression`. `select`
  prints three errors at `4:1` past the end of the file.
- Should say: only the first error, and accept the rejected name for the rest of
  the scope. (`on`, `after` and `with` as names are accepted; `on` as a use is
  `expected expression`.)
- Owner: discovery parser, `parse/parser_cursor.brp:611` (`ReservedKeywordAsName`);
  text in `diagnostics/render.brp:873`.
- Cost: S
- ROI: Medium. Agents name variables `type`, `from` and `in` often.

### DG-043 `try`, `except`, `with open`, `import x from y`, `from x import y`, `import list`
- Input: `try:` / `except:`, `with open("f") as f:`, `import x from y`
- Current output: `try` prints ten errors starting `expected expression`;
  `with open(...)` gives `expected `=` or `?=` after with binding` and ``type
  ascription with `as` was removed``; `import list` gives a good first error
  (``expected `:` after import`` with the `import:` hint) and three follow-ups;
  `from list import map` is a DG-007 cascade.
- Should say: for `try`/`except`: "Blorp has no exceptions; fallible functions
  return `Result` or `Option`; propagate with `?=` or handle with `match`".
- Owner: discovery parser, `parse/body_parser.brp` (statement and `with` forms),
  `parse/import_parser.brp`; text in `diagnostics/render.brp`.
- Cost: S
- ROI: Medium. Error handling is a first topic for anyone porting code.

### DG-044 Inclusive ranges, chained comparisons and valueless declarations
- Input: `for i in 0..=3:` (inclusive), `if 0 < x < 3:`, `x: Int` with no value,
  `var x: Int` then `x = 1`
- Current output: `..=` prints 15 errors; the chained comparison says
  `Comparison requires matching types that implement Orderable, got Bool and Int`;
  a declaration with no value says `expected expression` at the colon; `var x: Int`
  prints three errors starting at the next line.
- Should say: ranges are exclusive and `..=` does not exist (use `0..4`); chained
  comparison -> `0 < x and x < 3`; "every binding needs a value; write
  `x: Int = 0`".
- Owner: discovery parser, `parse/expression_atoms.brp:143`; typecheck `infer.brp:6589`.
- Cost: S each
- ROI: Medium.

### DG-046 A typo in an assignment target creates a new binding
- Input:
  ```
  var total: Int = 0
  totl = 5
  total
  ```
- Current output: `Type checking succeeded.` `totl` becomes a fresh immutable
  binding that nothing reads. `var x: Int = 1` that is never mutated and unused
  bindings are also silent.
- Should say: a lint (not an error, since `x = 5` is the declaration form) for a
  binding that is never read, with a did-you-mean for a near-matching `var`.
- Owner: `blorp/src/lint/`.
- Cost: M
- ROI: Medium. Silent typo class, but declaration-by-assignment is intended.

---

## Low ROI

### DG-050 Explicit generic call syntax
- Input: `f<Int>(1)`, `f[Int](1)`
- Current output: `error: `Int` is not a value`, then comparison and subscript
  errors (`Comparison requires matching types ... got (T) -> T and Void`).
- Should say: "type arguments are inferred; annotate the binding instead:
  `x: Int = f(1)`".
- Owner: stage_06_typecheck `infer.brp`.
- Cost: S
- ROI: Low. Needed rarely in a language that infers.

### DG-051 Declaration shapes `Int x = 1` and `f(Int x)`
- Input: `Int x = 1`, `func f(Int x) -> Int:`
- Current output: ``error: `Int` is not a value``; `expected `)` after function
  parameters` plus a cascade.
- Should say: "write the name first: `x: Int = 1`".
- Owner: discovery parser `parse/binder_parser.brp`; typecheck `infer.brp`.
- Cost: S
- ROI: Low. C and Java habits.

### DG-052 `if x:` on a non-Bool has no help
- Input: `if x:` with `x: Int`
- Current output: `If condition must be Bool, got Int`
- Should say: add "compare explicitly, `x != 0`". (A `pure func` reading a mutable
  module `var` is accepted: a purity question filed as CF-009.)
- Owner: stage_06_typecheck `infer.brp`.
- Cost: S
- ROI: Low.

---

## Checked and good

Do not re-probe these. Each prints a message at the right place, in the user's
terms, with enough to act on; the only gap on most is DG-001 (no location on a
semantic error).

Syntax, with `file:line:col` and a help line:
- `if x = 1:` and `while x = 1:` ("a condition cannot be an assignment ... use `==`").
- `a = b = 1`, `x = 1` inside an argument or lambda ("an assignment is a statement").
- `p.x = 2` ("field assignment is not supported ... use record update syntax").
- Missing `:` after `if`, `else`, `for`, `while`, `match` and a match arm.
- `break` outside a loop; `?=` inside a loop body (with the `match` alternative).
- An unterminated string; inconsistent dedent ("a tab counts as 4 columns");
  `'hello'` as a string; a unicode quote; `\` continuation; `;`.
- An unknown `@annotation` (lists the valid ones); the reserved-word-as-name first
  error (see DG-042 for the cascade).
- `&&` and `!` carry a hint (but see DG-008 for the cascade and DG-025 for `&`).
- `x as Int` ("type ascription with `as` was removed").
- `enum Shape: Circle(Float)` ("Enum variant ... cannot have fields; use 'union'").
- `struct S {name: String}` and a `record` field in a struct (names the reason and
  suggests a record).
- CF-003: a field name repeated in a `record` or `struct` declaration, a record literal or a
  record update reports ``duplicate field `x` `` at the second one and gives the first one's
  position (`record_duplicate_field_on_later_line.brp`, `struct_duplicate_field.brp`,
  `record_literal_duplicate_field.brp`, `record_update_duplicate_field.brp`).
- CF-002: a function with no body reports ``function has no body`` at its name unless
  a same-named top-level function supplies the body (a forward declaration, which ends in `:`) (`function_without_body.brp`,
  `forward_declaration_without_implementation.brp`); a header missing only its `:`
  reports ``expected `:` before function body`` and reads the body (`missing_colon_func.brp`).

Typecheck, correct message (location aside, DG-001):
- Non-exhaustive match on a union, `Bool`, `Option`, `Int` and `List` names the
  missing constructors or the catch-all to add.
- A pure function calling an impure one (`print`, a user function, `sleep`), a
  pure function assigning to a module variable, a closure capturing a `var`,
  an impure function passed where `pure` is required, `@tail_recursive` with a
  non-tail call.
- Record literal missing, extra or wrongly typed fields (with position); unknown
  field in an update or access (lists the valid fields).
- Argument type mismatch and match-branch mismatch (with position); mixed `if`
  branches; `if` without `else` used as a value; wrong `if`/`while` condition type.
- A function with no return type whose body has a value (with help); `main` with the
  wrong parameter or return type (with help); an integer literal too large or used
  as a `Float` (with help).
- `?=` in a function returning the wrong carrier (suggests `to_result`); `?=` result
  not wrapped; tuple index out of range; tuple destructuring arity.
- Wrong trait method signature, missing required method, unknown trait, unsatisfied
  bound, missing bound on `T` for `>`; duplicate import; duplicate union constructor.
- A wrong generic arity (`List[Int, Int]`, bare `List`); a for loop over a non-iterable
  (lists the iterable types); a list literal with a mixed element; an empty list with
  no type.
- Compile-time constant calling an impure function; an unknown function annotation.

Accepted correctly (the valid control programs): tab-indented blocks, a trailing
comma in a call or record, `var x = 1`, nested `func`, `x.sort()`/`xs.join(",")`
via UFCS, `o == None`, `-> ()` and `()`, `---` docstrings, `with`/`after` as names,
`print(5)`, and a library file with no `main`.
