# Interning a spelling copies the table's lists on a miss, and allocates a tuple per word

Status: open. The fixes are in `docs/VALUE_TUPLES_AND_STATE_HANDOFF.md`
(branch `core/value-tuples-and-state-handoff`, not yet landed).

The discovery lexer interns every word it meets with one call that returns the
table and the word's id together (the spec's `intern_slice`,
`docs/DISCOVERY_REDESIGN.md`, section 5.1):

```
pure func interned_spelling(
	spellings: Spellings,
	source: String,
	start: Int,
	end: Int,
) -> (Spellings, SpellingId):
	state: InternedSpellings = from_opaque Spellings(spellings)
	hash: Int = slice_hash(source, start, end)
	found: Int = find_slice(state.texts, state.slots, source, start, end, hash)

	if found == NO_ROW:
		row: Int = state.texts.length()
		(
			into_opaque Spellings(with_text_appended(state, source, start, end, hash)),
			spelling_id(state.module, row),
		)
	else:
		(spellings, spelling_id(state.module, found))
```

and the lexer calls it as

```
(interned, name_spelling) = interned_spelling(spellings, text, name_start, end)
spellings = interned
```

The function is correct and has no precondition to misuse. It costs two
things today, which are separate causes.

## Cause 1: a heap tuple per word

A `(Spellings, SpellingId)` result is a heap-allocated tuple, so every word the
lexer meets allocates once, hit or miss. A multi-value result that is returned
without a heap tuple removes it (`docs/VALUE_TUPLES_AND_STATE_HANDOFF.md`).

## Cause 2: the miss arm copies the table, from two shared references

The callee already owns `spellings` (the hit arm returns it, the miss arm
consumes it), but the table is shared when the miss arm's update runs:

- **The caller keeps its reference.** The caller retains its `var spellings`
  before the owned call and releases it only at the reassignment
  `spellings = interned`, so the table has two owners during the call. The
  `var` is not moved at its last use before the reassignment. Moving a `var` at
  its last use (inferred ownership, or release at last use, in the design above)
  removes this.
- **The alias is retained.** `state` is an alias of the table, retained at
  entry and passed on to `with_text_appended`, whose original takes it by
  borrow, so the update sees the alias as a second owner and copies the record
  and both lists: O(table size) per new spelling.

The probe `value_tuples/intern_probe.brp` (design branch scratch) measured
allocations at 1,000 / 10,000 calls, one in four a hit. A tuple result gave
3,251 / 32,501 whether the hit arm returned the given table or rebuilt it from
the alias, and a result of the table alone gave 19 / 25: so the hit arm
returning the given table is not the cause, and the tuple is not the only
cost.

## Evidence

On the self-compile inputs (`blorp/src/main.brp`, 449 modules), stage `tables`
mode, against the previous two-call interning (a lookup and an add the caller
branched on, which kept the table in place, with an API that could add a
spelling to the wrong table): +1.709 G instructions (5.212 G to 6.921 G,
+32.8%) and +1,062,386 allocations (753,757 to 1,816,143). The input holds
802,952 words (module tokens and the tokens of each interpolation hole) and
87,170 new spellings: 802,952 tuples + 3 x 87,170 copies = 1,064,462, within
0.2% of the rise. Per word, `test_lexer_allocations`:

- 1 allocation per word, hit or miss: 6,043 for 6,000 words (`foo bar baz`),
  where the pins were 32 before;
- 5 per new spelling, 10,030 for 2,000 distinct words: the text, the tuple, a
  new record and copies of the texts and slots lists; 2 (text and tuple) would
  be 4,043 with the table in place, and about 2,043 with no tuple.

(The same figures are in `benchmarks/results/discovery_redesign_m2_2026-10-02.md`.)

Pins that carry the cost, to tighten when the fixes land: the words, layout,
comment, dimension-name and new-spelling pins in
`blorp/test/compiler_new/stage_01_discovery/lex/test_lexer_allocations.brp`, and
the repeated-interpolation parse pin (3 words per hole pair, +6,000) in
`blorp/test/compiler_new/stage_01_discovery/tables/test_allocation_budget.brp`.

## What the compiler must do

- Return a multi-value result without a heap tuple.
- Move a `var` at its last use before the reassignment that replaces it, so
  the callee's owned table is not shared with the caller.
- Treat an alias of an owned value (`state`) as the same owner, so the update
  that consumes it runs in place, reading what it needs (`state.module`) before
  the move.
