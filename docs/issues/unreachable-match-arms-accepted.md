# Unreachable match arms are accepted

Status: open.

An arm that can never run is accepted silently: a constructor matched twice,
one already covered by an or-pattern, or any arm after a catch-all.

```
union Color:
	Red
	Blue

func name(c: Color) -> String:
	match c:
		Red: "red"
		Red: "also red"              -- unreachable
		Blue: "blue"

func fallback(c: Color) -> String:
	match c:
		_: "unknown"
		Red: "red"                   -- unreachable
```

Such an arm is almost always a mistake (a misspelled or copy-pasted case), and
principle 6 relies on the compiler to say so.

## Where to look

`check_match_exhaustiveness` in `stage_06_typecheck/infer.brp` computes
coverage but never asks whether an arm adds any. The coverage matrix proposed in
`nested-pattern-exhaustiveness-unchecked.md` answers both questions.

## Fixtures (4)

Under `blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_fail/`:
`duplicate_match_arm`, `duplicate_match_arm_after_or_pattern`,
`unreachable_after_or_pattern_catchall`, `unreachable_after_wildcard`.

## Acceptance

Each is rejected (or, if the owner decides unreachable arms are warnings, the
fixtures move to a warning fixture owner) with a message naming the arm and the
earlier arm that covers it; each passes `run_blorp_check_fixtures.py` and is
marked `-- RUN-BLORP-CHECK`.
