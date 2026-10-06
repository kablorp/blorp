# A nullary constructor of another type is accepted in a pattern

Status: open.

In a pattern, a nullary constructor that belongs to a different type than the
scrutinee is not reported. The checker accepts:

```
union Color:
	Red
	Blue

union Shape:
	Circle(Int)
	Square(Int, Int)

func test(s: Shape) -> Int:
	match s:
		Red: 0                       -- Red is a Color, not a Shape
		Circle(r): r
		Square(w, h): w + h

func main(args: List[String]) -> Int:
	print(to_string(test(Circle(5))))
	0
```

`bin/blorp run` then fails in the backend: the generated C contains
`#error "Blorp backend could not emit function body: test"`. `None` in a match
on a user union is accepted the same way. A constructor with a payload of
another type is rejected (``Unknown constructor pattern `Circle` ``), so only the
nullary form slips through the checker.

## Where to look

Identifier-pattern inference in `stage_06_typecheck/infer.brp` (near the
`Unknown constructor pattern` diagnostic): an identifier that names a
constructor visible in scope must be resolved as that constructor and checked
against the scrutinee's type, instead of being accepted as some other pattern.

## Fixtures (2)

Under `blorp/test/test_compiler/test_stage_06_typecheck/infer_fixtures/infer/should_fail/`:
`match_wrong_union_constructor`, `nullary_cross_type`.

## Acceptance

Both are rejected at typecheck naming the constructor and the type it belongs
to (for example `Constructor Red belongs to type Color, not Shape`) with a help
line, pass `run_blorp_check_fixtures.py`, and are marked `-- RUN-BLORP-CHECK`.
