# Learn Blorp in Y Minutes

This is a concise, opinionated tour of Blorp. It is meant for humans learning
the language and for agents generating Blorp code. For complete details, use
`docs/GUIDE.md`. For parser-level syntax, use `docs/GRAMMAR.md`.

Blorp is a compiled functional language with value semantics, explicit purity,
algebraic data types, pattern matching, traits, structured concurrency, and
native code generation through C.

## The Shape of Good Blorp

Prefer this style:

- Write pure functions by default. Use `func` only when the function really has
  effects such as I/O, sleeping, channels, or process/system calls.
- Use immutable bindings by default. Reach for `var` only for local
  accumulators or clear step-by-step construction.
- Model states with `enum`, `union`, `record`, and `struct`; do not smuggle
  state through magic integers or strings.
- Keep enums to real domain cases. Use `Option[T]` for absence/disabled state
  and `Result[T, E]` for parse or validation failure instead of adding escape
  variants such as `Unknown`, `Invalid`, or `Off`.
- Use `match` for branching over booleans, options, results, unions, enums, and
  list shapes.
- Use UFCS method chains for left-to-right data flow: `items.filter(...).map(...)`.
- Use `Option`/`Result` for genuinely fallible operations. Do not wrap values
  in `Option` when the operation can be infallible by design.
- Use `?=` to propagate `Option`/`Result` failures from straight-line code.
- Use `concurrent:` for structured parallel work. Use `detach` only when
  fire-and-forget is intentional.
- Never write global `pure` functions that take no arguments and return a constant; use
  constants instead.

## Hello

```blorp
func main(args: List[String]):
	print("hello, blorp")
```

Run it:

```bash
./blorp run hello.brp
./blorp check hello.brp
./blorp format --check hello.brp
```

`main` may return `Int` for an exit code or omit the return type, which is equivalent to using `Void`.

## Bindings

```blorp
PI: Float = 3.141592653589793

pure func bindings() -> Int:
	x: Int = 10       -- immutable
	y = 20            -- type inferred

	var total: Int = 0
	total = total + x
	total += y

	(a, b) = (1, "one")
	total + a + b.length()
```

Top-level bindings are constants. Inside functions, `name = value` creates an
immutable local binding and `var name = value` creates a mutable local binding.
Mutable locals are allowed in `pure func` because local mutation is not an
observable side effect.

## Functions and Lambdas

```blorp
pure func square(x: Int) -> Int:
	x * x

func log_square(x: Int) -> Void:
	print("square=${square(x)}")

pure func identity[T](x: T) -> T:
	x

pure func sum(nums: List[Int]) -> Int:
	var total: Int = 0
	for n in nums:
		total += n
	total

pure func doubled(nums: List[Int]) -> List[Int]:
	nums.map(pure func(n): n * 2)
```

Use `pure func` when a function is deterministic and has no side effects. A
pure function cannot call an impure function. A pure lambda uses
`pure func(...)`.

## Expressions and Control Flow

`if` and `match` blocks are expressions. Loops return `Void`.

```blorp
pure func sign_name(n: Int) -> String:
	if n < 0:
		"negative"
	else if n == 0:
		"zero"
	else:
		"positive"

pure func sum_positive(nums: List[Int]) -> Int:
	var total: Int = 0
	for n in nums:
		if n > 0:
			total += n
	total

func print_until_zero(nums: List[Int]) -> Void:
	for n in nums:
		if n == 0:
			break
		print(n.to_string())
```

Prefer `match` once the branches are about data shape rather than a simple
condition.

## Strings

```blorp
name: String = "Ada"
message: String = "hello, ${name}"
raw_pattern: String = raw"\d+\.\d+"

html: String =
	|<section>
	|  <h1>${name}</h1>
	|</section>
```

String interpolation uses `${expr}`. Raw strings do not process escapes or
interpolation. Multi-line strings use left-aligned pipes to make padding explicit.

## Method Syntax

Method syntax means `x.f(y)` is `f(x, y)`. This is the preferred way to compose
ordinary functions.

```blorp
pure func clean_scores(scores: List[Int]) -> List[String]:
	scores
		.filter(pure func(n): n >= 0)
		.map(pure func(n): n * 2)
		.sort()
		.map(pure func(n): n.to_string())
```

Prelude types such as `List`, `String`, `Option`, `Result`, `Dict`, and `Set`
have common methods available without imports. Import non-prelude types or
bare functions explicitly.

## Records, Structs, Enums, and Unions

Use `record` for most product data.

```blorp
record User {
	name: String,
	age: Int
}

pure func birthday(user: User) -> User:
	{ user | age = user.age + 1 }
```

Use `struct` for small stack values with primitive fields.

```blorp
struct Vec2 {x: Float, y: Float}

pure func add(a: Vec2, b: Vec2) -> Vec2:
	{x = a.x + b.x, y = a.y + b.y}
```

Use `enum` for a closed set of simple named cases.

```blorp
enum LogLevel:
	Debug
	Info
	Warn
	Error

pure func level_name(level: LogLevel) -> String:
	match level:
		Debug: "debug"
		Info: "info"
		Warn: "warn"
		Error: "error"
```

Do not add escape variants to an enum just to represent absence, disabled
behavior, or failure. For example, a disabled logger can store
`Option[LogLevel]`, and parsing a level from text can return
`Result[LogLevel, ParseError]`.

Use `union` when variants carry data.

```blorp
union Command:
	Quit
	Move(Int, Int)
	Say(String)

pure func describe(cmd: Command) -> String:
	match cmd:
		Quit: "quit"
		Move(dx, dy): "move ${dx},${dy}"
		Say(text): "say ${text}"
```

The compiler checks `match` exhaustiveness for unions, enums, booleans, and
lists. Prefer explicit cases over defaulting to `_` when missing a case should
be a future compile error.

## Option, Result, and `?=`

Use `Option[T]` when a value may be absent. Use `Result[T, E]` when failure
needs an explanation.

```blorp
pure func safe_div(a: Int, b: Int) -> Option[Int]:
	if b == 0:
		None
	else:
		Some(a / b)
```

For `Result`, `?=` binds `Ok(value)` and returns `Err(error)` from the
enclosing function. These two functions are equivalent; the second is the
preferred Blorp shape.

```blorp
record Account {
	name: String,
	email: String
}

union SignupError:
	EmptyName
	InvalidEmail(String)
	DisposableEmail(String)

pure func require_name(name: String) -> Result[String, SignupError]:
	cleaned: String = name.trim()
	if cleaned.length() == 0:
		Err(EmptyName)
	else:
		Ok(cleaned)

pure func require_email(email: String) -> Result[String, SignupError]:
	cleaned: String = email.trim().lower()
	if cleaned.contains("@"):
		Ok(cleaned)
	else:
		Err(InvalidEmail(email))

pure func reject_disposable(email: String) -> Result[String, SignupError]:
	if email.ends_with("@example.com"):
		Err(DisposableEmail(email))
	else:
		Ok(email)

-- Works, but nests failure plumbing inside success plumbing.
pure func create_account_pyramid(name: String, email: String) -> Result[Account, SignupError]:
	match require_name(name):
		Err(err): Err(err)
		Ok(valid_name):
			match require_email(email):
				Err(err): Err(err)
				Ok(valid_email):
					match reject_disposable(valid_email):
						Err(err): Err(err)
						Ok(accepted_email):
							Ok({name = valid_name, email = accepted_email})

-- Equivalent, but keeps the success path flat.
pure func create_account(name: String, email: String) -> Result[Account, SignupError]:
	valid_name ?= require_name(name)
	valid_email ?= require_email(email)
	accepted_email ?= reject_disposable(valid_email)
	Ok({name = valid_name, email = accepted_email})
```

Rules of thumb:

- `?=` is for straight-line propagation.
- Use `match` when recovery or branching is local.
- Success values are not auto-wrapped; return `Some(...)` or `Ok(...)`
  explicitly.
- `?=` is not allowed inside loop bodies. Use `match` in the loop or move the
  propagation outside the loop.

## Pattern Matching

```blorp
pure func first_or_zero(nums: List[Int]) -> Int:
	match nums:
		[]: 0
		[x, ...rest]: x

pure func classify(value: Option[Int]) -> String:
	match value:
		Some(0): "zero"
		Some(n): "number ${n}"
		None: "missing"

pure func is_warm(level: LogLevel) -> Bool:
	match level:
		Debug | Info: False
		Warn | Error: True
```

Use `_` for intentional "anything else". Prefer named variables when the value
matters, and prefer exact constructors when exhaustiveness should protect you.

## Imports and Modules

Each `.brp` file is a module. Imports use a single `import:` block.

```blorp
import:
	heap as H: Heap

func heap_demo() -> Int:
	var heap: Heap[Int] = H.heap()
	heap = heap.push(42)
	heap.size()
```

Import styles:

- `module: name` imports symbols by bare name.
- `module as M` imports the module for qualified access, such as `M.make()`.
- `module as M: Type` does both, and importing a type enables that module's
  first-argument functions as UFCS methods for the type.
- There are no wildcard imports.
- Declarations are public by default. Use `private` for module-local helpers.

## Traits

Traits define behavior. `implements` attaches behavior to a type.

```blorp
record Color {r: Int, g: Int, b: Int}

implements Stringable for Color:
	pure func to_string(c: Color) -> String:
		"rgb(${c.r}, ${c.g}, ${c.b})"

implements Equatable for Color:
	pure func equals(a: Color, b: Color) -> Bool:
		a.r == b.r and a.g == b.g and a.b == b.b
```

Operators are trait-driven. Implement `Equatable` for `==` and `!=`,
`Orderable` for comparisons, and arithmetic traits such as `Addable` for
operators such as `+`.

```blorp
pure func max_value[T: Orderable](a: T, b: T) -> T:
	if a > b:
		a
	else:
		b
```

Keep trait implementations in the module that owns the trait or the type. If
you need behavior for a type you do not own, wrap it in a local type first.

## Concurrency

Use `concurrent:` when all spawned work should be joined before the program
continues.

```blorp
func fetch_user() -> String:
	sleep(10)
	"ada"

func fetch_score() -> Int:
	sleep(10)
	42

func load_profile() -> Result[String, ConcurrencyError]:
	concurrent(timeout: 1000):
		user = fetch_user()
		score = fetch_score()

	name ?= user
	points ?= score
	Ok("${name}: ${points}")
```

Each binding in a `concurrent:` block becomes `TaskResult[T]`, an alias for
`Result[T, ConcurrencyError]`.
Timeouts are cooperative and happen at yield points such as `sleep`, channel
operations, and joins.

Use `for ... concurrently(limit: N)` for side-effecting fan-out with explicit
width:

```blorp
func index_pages(pages: List[Int]) -> Void:
	for page in pages concurrently(limit: 4):
		print("index ${page}")
```

Use channels for communication:

```blorp
func send_one(ch: Channel[Int]) -> Void:
	_ = send(ch, 1)
	seal(ch)

func receive_one() -> Option[Int]:
	ch: Channel[Int] = channel(1)
	detach send_one(ch)
	recv(ch)
```

Use `detach` sparingly. It is explicit fire-and-forget work, not structured
concurrency.

## Resources

Use `with` for scoped resources. Resource handles stay inside the block so
cleanup ownership is deterministic.

```blorp
import:
	fs: open_read

func load_text(path: String) -> Result[String, IOError]:
	with reader ?= open_read(path):
		reader.read_text()
```

Use `with name ?= acquire():` for fallible resource acquisition. Do not unwrap
resource acquisitions with ordinary `?=` outside a resource scope.

## Foreign Functions

Blorp can call C through `foreign:` blocks. Keep native bindings in `pkg/`
unless they are compiler/runtime primitives already owned by `std/`.

```blorp
foreign(include: "math.h", link: "-lm"):
	pure func c_sqrt(x: Float) -> Float = "sqrt"
```

Wrap foreign functions in ordinary Blorp functions that enforce the safe,
infallible behavior callers should see.

## Fixed-Size Arrays

Use postfix dimensions for compile-time sized numeric arrays:

```blorp
pure func dot3(a: Float[#3], b: Float[#3]) -> Float:
	a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

v: Float[#3] = {1.0, 2.0, 3.0}
m: Float[#2, #3] = {{1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}}
row: Float[#3] = m[0]
cell: Float = m[1, 2]
```

Use `List[T]` for runtime-sized data. Use `T[#N]` and `T[#M, #N]` when shape is
known statically and should be checked by the compiler.

## Testing

Runtime tests are ordinary Blorp files that export a `TestSuite`.

```blorp
import:
	test: TestSuite

pure func square(x: Int) -> Int:
	x * x

pure func test_square() -> Bool:
	square(6) == 36

tests: TestSuite = {
	description = "Math",
	tests = [
		("square", test_square),
	]
}
```

Run tests:

```bash
./blorp test tests/test_blorp/types/test_bool.brp
scripts/test runtime
scripts/test compiler-blorp
```

## Common Agent Mistakes to Avoid

- Do not invent null, exceptions, classes, inheritance, or shared mutable
  references.
- Do not model closed sets as `Int` constants; use `enum`.
- Do not add escape variants such as `Off`, `Unknown`, or `Invalid` to enums
  when `Option` or `Result` would state the surrounding condition directly.
- Do not model data-carrying variants as records plus tag fields; use `union`.
- Do not add `Option` around infallible operations such as `length`.
- Do not capture `var` bindings in closures.
- Do not use `detach` when `concurrent:` gives the desired lifetime.
- Do not add a native dependency to `std/`; put optional native bindings under
  `pkg/`.
- Do not rely on generated C shape as the source language contract.

## Where to Go Next

- `docs/GUIDE.md` for the full language reference.
- `docs/GRAMMAR.md` for parser syntax.
- `docs/MEMORY_MODEL.md` for value semantics, ARC, and COW.
- `docs/ARCHITECTURE.md` for compiler pipeline details.
- `std/*.brp` and `tests/test_blorp/**/*.brp` for current idioms.
