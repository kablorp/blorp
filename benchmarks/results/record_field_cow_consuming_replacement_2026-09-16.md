# Record-Field COW-Consuming Replacement: Field Take

Confirms, with an isolated microbenchmark and generated-C inspection, that
threading a small state record through a loop and updating one `List` field
via a COW-consuming call on that same field (`{ s | items = s.items.append(x),
... }` or the equivalent record literal) defeated the unique-ownership fast
path for that call on every iteration, while a bare top-level `List` local did
not; then records the effect of the `CowFieldTakeRetainPolicy` rewrite that
fixes the record-update form (see the Fix section at the end).

Host: Darwin arm64 (M-series), baseline commit
`5dba1cbb244ee1a223607bc123b90b1e9231485d`, built via `make` (bootstrap
default, no `--release`). `bin/blorp --version` reports `0.0.1`. Post-fix
numbers were taken on the same host from the fix commit's working tree on top
of `4741dce9`.

## Microbenchmark

Three `func run() -> Int` variants, each looping `i` from `0` to `n` and
building up a `List[Int]` by repeated `.append(i)`, measured with
`bin/blorp run --no-format --leak-check --timeout 60 <file>`. Allocation
counts are exact (leak-checker instrumentation, not sampled), so single runs
are sufficient; three values of `n` establish the scaling shape.

**A. Bare local** — `var items: List[Int] = []`, loop body `items =
items.append(i)`.

**B. Record-update form** — `record State { items: List[Int], top: Int }`,
`var s: State = {items = [], top = 0}`, loop body
`s = { s | items = s.items.append(i), top = i }`.

**C. Record-literal rebuild** — same `State`, loop body
`s = {items = s.items.append(i), top = i}` (no `{ s | ... }` sugar).

| n | A: bare local allocs | B: record-update allocs | C: record-literal allocs |
| ---: | ---: | ---: | ---: |
| 5,000 | 16 | 5,005 | (not run; C tracks B plus one record alloc/iter) |
| 10,000 | 17 | 10,005 | (not run) |
| 20,000 | 18 | 20,005 | 40,005 |

A grows logarithmically (amortized-doubling growth, O(1) amortized per
append). B and C both grow as `n + O(1)` — essentially one full list
reallocation-and-copy every single iteration, turning an O(n) amortized
builder loop into O(n²) total copied elements. C is roughly `2n` because it
additionally loses the record-reuse fast path that B's `{ s | ... }` form
keeps (no separate record allocation per iteration in B; one in C).

Exact sources (n=20000 shown; 5,000/10,000 rows used the same files with the
`20000` literal substituted), not retained as committed fixtures:

`bare_local.brp`:

```blorp
func run() -> Int:
	var items: List[Int] = []
	var i: Int = 0
	while i < 20000:
		items = items.append(i)
		i = i + 1
	items.length()

func main(args: List[String]):
	print(run().to_string())
```

`record_threaded.brp`:

```blorp
record State {
	items: List[Int],
	top: Int
}

func run() -> Int:
	var s: State = {items = [], top = 0}
	var i: Int = 0
	while i < 20000:
		s = { s | items = s.items.append(i), top = i }
		i = i + 1
	s.items.length()

func main(args: List[String]):
	print(run().to_string())
```

`record_literal.brp`: identical to `record_threaded.brp` except the loop body
is `s = {items = s.items.append(i), top = i}` (plain record literal, no
`{ s | ... }` update sugar).

Commands used:

```bash
bin/blorp run --no-format --leak-check --timeout 60 bare_local.brp
bin/blorp run --no-format --leak-check --timeout 60 record_threaded.brp
bin/blorp run --no-format --leak-check --timeout 60 record_literal.brp
```

## Mechanism, confirmed in generated C

```bash
bin/blorp compile --no-format -o record_threaded.c record_threaded.brp
```

At the `.append()` call site inside the loop, generated C shows the field
pulled out as a locally-retained alias before the COW-consuming call:

```c
blorp_List* __std_inline_self = ({
    blorp_List* __blorp_internal_perceus_owned_result = s->items;
    blorp_retain(__blorp_internal_perceus_owned_result);
  __blorp_internal_perceus_owned_result;
});
...
(__builtin_expect(__list_cap_ensure && blorp_is_unique(__list_cap_ensure)
    && __list_cap_ensure->capacity >= __list_cap_min_ensure, 1)
  ? __list_cap_ensure
  : blorp_list_ensure_capacity(__list_cap_ensure, __list_cap_min_ensure));
...
State* __record_reuse_result_9 = __blorp_reuse_record_State(s, __record_field_7, __record_field_8);
s = __record_reuse_result_9;
```

`s->items` is read as `FieldExpr(VarExpr(s), items)`, which Perceus's
`direct_field_alias` classifies as a borrow, not an owned value
(`blorp/src/compiler/stage_09_core/perceus.brp:13852`). Because
[`OWNERSHIP_MODEL.md`](../../docs/OWNERSHIP_MODEL.md#cow-abi) requires "a
borrowed field or collection-element alias cannot be passed directly to a
consuming COW slot; it must first become an independent retained owner," the
generated code retains `s.items` before passing it to `.append()`'s
consuming argument slot. That retain runs while `s` (and its `items` field
slot) is still alive — record-update lowering evaluates every replacement
before consuming the source
(`OWNERSHIP_MODEL.md#fieldwise-record-updates`) — so `blorp_is_unique`
observes refcount 2, not 1, and takes the copy branch every time.
`__blorp_reuse_record_State` shows the record's own allocation *is* reused
(consistent with B's lower allocation count than C); only the `List` field's
uniqueness is lost.

`blorp/src/compiler/stage_09_core/record_update.brp:451-478`
(`record_field_references_itself`/`inherited_record_field`) already special-
cases a field replaced with a literal passthrough of itself (`items =
s.items`), but not a field replaced by a COW-consuming call on itself
(`items = s.items.append(...)`); that call is classified as an ordinary
`replacement` field (lines 269-274) and gets no such treatment.

## Self-host relevance

The same shape (`{ state | field = state.field.append(...)/.set(...) }`
against a `List` field of a threaded state record) appears at least 38 times
across 18 files under `blorp/src/compiler/` as of this commit, including hot
paths in `stage_02_lex/lexer.brp`, `stage_06_typecheck/infer.brp`, and
`stage_06_typecheck/type_system/env.brp`:

```bash
grep -rlE '\{\s*[a-zA-Z_]+\s*\|.*=\s*[a-zA-Z_]+\.[a-zA-Z_]+\.(append|set|push|prepend)\(' \
  blorp/src/compiler/ | wc -l   # 18 files
```

This is a lower bound (single-line, one-field-per-line regex; multi-line
record updates and other COW-mutating methods are not counted). Not
independently profiled against a self-compile baseline in this pass.

## Fix

The reuse pass now rewrites the retain in Perceus's owned-alias shape to
`CowFieldTakeRetainPolicy(source, field)` when the update source is a bare
consumed variable, the alias sits on the straight-line evaluation spine of
that field's own replacement, and no other replacement reads that field or
the whole record (a direct read of a different field is allowed). The backend
emits `if (blorp_is_unique(s)) { s->items = NULL; } else { blorp_retain(t); }`
in place of the unconditional retain; the contract is in
[`OWNERSHIP_MODEL.md`](../../docs/OWNERSHIP_MODEL.md#fieldwise-record-updates).
The pass also had to start visiting `AssignExpr` right-hand sides, which it
previously returned untouched, so loop bodies were reachable at all.

Same host and inputs, n=20,000, `--leak-check` allocation counts:

| Program | Before | After |
| --- | ---: | ---: |
| A. bare local | 18 | 18 |
| B. `{ s \| items = s.items.append(i), top = i }` | 20,005 | 19 |
| `{ s \| items = s.items.append(i) }` (partial update) | 20,005 | 19 |
| `{ s \| items = s.items.append(i), top = s.top + 1 }` | 20,005 | 19 |
| C. `{items = s.items.append(i), top = i}` (fresh literal) | 40,005 | 40,005 |

C is unchanged by design: a fresh record literal is a `RecordExpr`, not a
consuming record update, so the source is not proven dead when the field is
read. `docs/MEMORY_MODEL.md` documents which shapes keep the fast path.

Correctness evidence: an aliasing program (shared base, mid-loop snapshots,
two owners of the same record before an update) prints identical results
under `--leak-check` (31 allocs, 31 releases, 0 leaked) and `--sanitize`;
`blorp/test/runtime/types/test_record_cow.brp` gained an allocation-bounded
loop test and an alias-preservation test and passes with `--leak-check`.

## Self-compile measurement (stage 2, -O2): neutral

Because the fix changes generated code, a compiler built by the pinned
bootstrap does not contain it; the measurement therefore used stage-2
compilers (each compiler rebuilt with itself as `BLORP_BOOTSTRAP_COMPILER_BIN`)
for both base commit `4741dce9` and the candidate, `BLORP_CLI_C_OPTIMIZATION=-O2`,
input `0c2e104331a224226088519bb0509c00b9ac0b70`, 3 samples, same host.
Retained JSON: `self_compile_field_take_base_stage2_O2_2026-09-16.json`,
`self_compile_field_take_stage2_O2_2026-09-16.json`, and the `small_` pair.

| metric | base stage 2 | candidate stage 2 | delta |
| --- | ---: | ---: | ---: |
| allocs late_core_complete | 88,635,270 | 88,735,644 | +0.11% |
| allocs TOTAL | 263,610,803 | 263,710,596 | +0.04% |
| instructions retired (min) | 256,657,365,257 | 256,815,352,576 | +0.06% |
| ms phase_total (median) | 20,241.9 | 20,384.2 | +0.70% |
| peak RSS | 2,331,066,368 | 2,336,849,920 | +0.25% |
| output C | 130,113,145 B | 130,236,413 B | DIFFERENT (expected) |

Small program: allocations +11 (0.00%), instructions +0.08%, output
IDENTICAL. Every other self-compile phase is allocation-identical; the
`late_core` increase is the reuse pass's own touch counting.

The candidate's generated C for the compiler contains 1,476 field-take sites
(top fields: `diagnostics` 98, `errors` 64, `type_shape_memo` 62, `context`
62, `state` 59), yet total allocations did not fall. So at those sites the
record is shared when the update runs — the dominant compiler shape is
`state = helper(state, x)` where the helper's `{ state | field =
state.field.append(x) }` sees a borrowed parameter while the caller still
holds the record — and the take correctly falls back to the retain. Turning
that into a win needs the caller to hand ownership to the callee (consumed
parameter specialization), which is a separate lever; this change only
removes the copy where the record is already unique, as in a loop-local
`var`.

## Caveats

The microbenchmark allocation count is a proxy, not a latency claim, and its
`n` values are small relative to a self-compile-shaped input; only the
allocation-scaling shape was established there. The self-compile numbers are
a single 3-sample pair per program on one host, sufficient to show the change
is neutral for compiler time, not to rank sub-percent effects.
