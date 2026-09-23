# Emitted C review — 2026-09-23

Reviewed for redundant / repeated / dead / oversized emitted C, per Keith's
suspicion that recent additive changes have bloated codegen.

## Method

- Built at `-O0` via `make` at commit `0bacd738dcc3` (main, `c-type-ids-3`
  worktree base). Build succeeded (8-way split, `bin/blorp` installed).
- Emitted the self-compile artifact:
  `bin/blorp compile --no-embed-runtime --no-format -o /tmp/blorp_scratch/self.c blorp/src/main.brp`
  → 96,988,108 bytes, 1,579,970 lines (matches the ~1.5M-line / 150MB
  expectation once you account for `--no-format` not being identical to the
  default embed-runtime build).
- Emitted two small programs the same way for full-function reading:
  - `/tmp/blorp_scratch/records.brp` / `.c` (829 lines) — records, a union,
    `?=`, record-update syntax.
  - `/tmp/blorp_scratch/loops.brp` / `.c` (770 lines) — `for`, `while`,
    recursion, `map`/`filter`/`sort` pipelines, a merge sort over `List[Int]`.
- Parsed `self.c` into 27,368 real top-level C functions with a brace-depth
  script (naive column-0 heuristics undercount because `--no-format` output
  has no indentation at all — nested `({ ... })` blocks also start at column
  0, so a depth-tracking pass was required to find true function
  boundaries). Sampled the 15 largest, 15 median (~13 lines), and 15
  smallest (≥4 lines) programmatically, then read full bodies of the two
  small programs (100% coverage) and multiple large real functions in
  `self.c` end-to-end against their Core/emit.brp provenance. Total functions
  read in full or by representative excerpt: comfortably over 40.
- Cross-referenced every pattern against its emitting site in
  `blorp/src/compiler/stage_10_backend/emit.brp` (and
  `prepared_backend_renderer.brp`) by grep on distinctive emitted tokens.

Function-size stats over the self-compile: 27,368 functions, mean 55.3
lines, median 13 lines — a small number of huge functions (the largest is
40,716 lines: `brp_5Vt`, the CLI argument-parsing dispatcher) sit next to a
long tail of tiny near-boilerplate constructors/destructors.

## Ranked findings (bytes, largest first)

### 1. Per-branch cleanup pop/push duplication from `emit_bound_let_body` / match-arm lowering

**What**: every `let`-cleanup pop (`blorp_task_cleanup_pop_slot_with_task`),
push (`blorp_task_cleanup_push_with_task`), and duplicate-slot registration
(`blorp_task_cleanup_duplicate_slot_with_task`) is emitted directly at each
point of use in the Core tree. When a `match` (from `?=`, union destructuring,
or Perceus-inserted variable-liveness matches) has many arms and a borrowed
variable is live going into the match, **every arm that consumes/drops that
variable re-emits its own pop+release**, instead of the match sharing one
pop for a scrutinee/borrow that is uniform across all its exits.

**Excerpt** (from `self.c:847951`, `brp_2aN`, a type-unification dispatcher
with ~40 match arms over two `SemanticType` unions — 1 `push`/`duplicate_slot`
pair per parameter, 79 pops):

```c
static void* brp_2aN(... left, right ...) {
void* const __blorp_task = __blorp_current_task;
blorp_retain(left);
blorp_task_cleanup_duplicate_slot_with_task(&left, __blorp_task);
blorp_retain(right);
blorp_task_cleanup_duplicate_slot_with_task(&right, __blorp_task);
...
if (...tag == ...SemanticNamedType) {
  ...
  blorp_task_cleanup_pop_slot_with_task(&left, __blorp_task);
  blorp_release(left);
  blorp_task_cleanup_pop_slot_with_task(&right, __blorp_task);
  blorp_release(right);
  ...
} else {
  ...
  if (...tag == ...SemanticNamedType) {
    blorp_task_cleanup_pop_slot_with_task(&left, __blorp_task);
    blorp_release(left);
    ...
  } else {
    // next arm, same pop+release pair again, etc. (repeats ~40x)
```

Blorp source is `unify_step` in
`blorp/src/compiler/stage_06_typecheck/type_system/*` (large `match` over
two nested unions); the duplication is introduced entirely by the emitter,
not by the source shape.

**Count** (whole self-compile): 72,277 `pop_slot_with_task` calls vs. 27,928
`push_with_task` + 9,116 `duplicate_slot_with_task` = 37,044 registrations —
i.e. **35,233 more pops than registrations**, meaning on average every
push/dup is popped roughly twice, and some (like `brp_2aN`, 2 registrations /
79 pops) far more.

**Bytes**: `pop_slot_with_task` call text alone is 4,905,701 bytes (72,276
matches); `push_with_task` is 4,650,875 bytes (27,928); `duplicate_slot` is
624,835 bytes (9,116). **Total ≈ 10.2 MB**, ~10.5% of the 97 MB file, before
counting the paired `blorp_release`/`blorp_retain` calls sitting next to most
of them (2.73 MB / 2.19 MB respectively, though not all retains/releases are
cleanup-adjacent).

**Emitting site**: `blorp/src/compiler/stage_10_backend/emit.brp`:
- `cancellation_cleanup_pop_statement` (line 2569) / push counterpart —
  single-statement renderers, called once per exit site.
- `emit_bound_let_body` (~line 12724) calls `apply_let_cleanup_to_body` per
  `let`, which appends the pop text to whichever body followed; nested lets
  inside match arms each get their own pop.
- `emit_resource_cleanups` (line 20585) and the match-scrutinee cleanup path
  around line 20560–20605 do the analogous thing for match scrutinees.

**Runtime cost**: not just bytes — each duplicated pop+release is also
duplicated *work* at runtime (one extra cleanup-list unlink + refcount
decrement per arm taken), so this is not purely a text bloat issue.

**Fix classification**: **changes runtime work** to fix properly (would want
a single shared pop at the match's post-dominator point, or one pop per
variable per function-exit rather than per source-level `let`/arm) — a purely
textual dedupe is possible only if the pop sites are truly redundant (i.e.
provably on every path), which needs dataflow, not sed.

---

### 2. `list_ensure_capacity`/push std-inline expansion duplicated at every call site

**What**: `List.push`/append the compiler `std_inline`s is expanded to its
full body (retain, a `blorp_is_unique && capacity >= n` ternary guarding a
call to `blorp_list_ensure_capacity`, `retain_for`, `set_raw`, and a `len`
update) as a `({ ... })` statement expression at **every call site**, instead
of being a single small `static inline` C helper function.

**Excerpt** (`self.c:174154`, one of thousands of near-identical sites):

```c
({ blorp_List* __list_cap_ensure = (blorp_List*)__call_arg_13;
   long __list_cap_min_ensure = __call_arg_14;
   (__builtin_expect(__list_cap_ensure && blorp_is_unique(__list_cap_ensure)
       && __list_cap_ensure->capacity >= __list_cap_min_ensure, 1)
     ? __list_cap_ensure
     : blorp_list_ensure_capacity(__list_cap_ensure, __list_cap_min_ensure));
});
```

Blorp source: any `list.append(x)` / `List.push` call gets this treatment
via std-inlining (`blorp/src/compiler/stage_09_core/std_inline/`), rendered
by `emit_prepared_list_intrinsic_call` → `render_prepared_list_op(EnsureCapacity(...))`
in `emit.brp` (~line 4436) / `prepared_backend_renderer.brp`.

**Count**: 3,979 occurrences of the ensure-capacity ternary alone
(`grep -c` on the distinctive `__list_cap_ensure ... blorp_list_ensure_capacity` idiom).

**Bytes**: 1,281,215 bytes for the ensure-capacity ternary text alone; the
surrounding retain/`retain_for`/`set_raw`/len-update lines that go with each
push site add roughly as much again, for an estimated **2.5–3 MB total**.

**Emitting site**: `emit_prepared_list_intrinsic_call` (emit.brp ~line 4424)
dispatches `"list_ensure_capacity"` to `render_prepared_list_op(EnsureCapacity(...))`;
the renderer is in `prepared_backend_renderer.brp`.

**Fix classification**: **text-only**. This body has no per-call-site
specialization opportunity worth keeping inline (it's already generic over
list/capacity); wrapping it in one `static inline` runtime helper (or a
compiler-emitted one-shot per translation unit) and calling it would collapse
thousands of copies into one function body with an ordinary call, at the
cost of a call/return the optimizer can still inline where it's hot.

---

### 3. Redundant `__let_result_N` temporary from `apply_let_cleanup_to_body`

**What**: when a `let`'s cleanup text must be appended after the body value
is computed, `apply_let_cleanup_to_body` (emit.brp line ~12805) *always*
introduces a fresh named temporary to hold `body_c.value`, even when
`body_c.value` is already a bare variable name that the cleanup text does
not release or otherwise invalidate. The result is a throwaway rename:
declare, immediately pop, immediately re-read once.

**Excerpt** (`self.c` line 522, inside `brp_ne` / `List.map`):

```c
blorp_List* __let_result_1 = __result;
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
__let_result_1;
```

`pop_slot_with_task` only removes `__result`'s cleanup-list registration; it
does not release or mutate `__result`, so this is exactly equivalent to:

```c
blorp_task_cleanup_pop_slot_with_task(&__result, __blorp_task);
__result;
```

**Count**: 10,410 declaration sites (`__let_result_N =`), each paired with a
later bare read of the same name (16,205 total token occurrences of
`__let_result_`).

**Bytes**: 930,815 bytes for the declaration lines alone; the paired bare
read line adds roughly another 250–350 KB → **≈ 1.2 MB**.

**Emitting site**: `apply_let_cleanup_to_body`, `emit.brp` line ~12805
(the `else:` branch that always synthesizes `result_name = temp_name("let_result", ...)`).

**Fix classification**: **text-only, and easy**. Special-case
`body_c.value` already being a bare C identifier (no side effects to
sequence): emit the cleanup text followed directly by that identifier as the
new `value`, skip the temp declaration entirely. When `body_c.value` is a
non-trivial expression the temp is still needed (to avoid re-evaluating or
reordering around the cleanup), so this is a narrow, safe special case, not
a rewrite of the whole function.

---

### 4. Near-identical per-variant destructor case bodies (record/union `_destroy`)

**What**: every generated `_destroy` function for a union with boxed
payload fields uses a `switch (self->tag)` with one `case` per variant, and
each case that has a releasable field emits the same three-line shape:
`case TAG_...: if ((self->release_mask & N) && self->data.V.fieldK) blorp_release(...); break;`
— the only things that vary are the (long, fully-qualified) tag name and
field path. This is architecturally sound (each case is genuinely a
different offset) but the *text* for each variant is boilerplate that could
be table-driven (a static `{offset, mask_bit}` array plus one shared loop)
without changing the union's memory layout.

**Excerpt** (`self.c:67684`, `PreparedBackendOp_destroy`, one of many
variants):

```c
case TAG_..._PreparedBackendOp_BackendDictCtorCustom:
    if ((self->release_mask & 1UL) && self->data.BackendDictCtorCustom.field0)
      blorp_release(self->data.BackendDictCtorCustom.field0);
  break;
```

**Count**: 1,869 `case TAG_...:` labels across 2,067 `_destroy` functions in
the self-compile; 2,533 of the case bodies are exactly this
single-nullable-field-release shape.

**Bytes**: case labels alone are 196,045 bytes (long, fully-qualified names
dominate); the release-guard lines are 339,269 bytes. Total for this
mechanical shape ≈ **550–650 KB** including `break;` lines. Not huge on its
own, but compounds with pattern 5 below (long names) and is the most
"boilerplate-shaped" candidate for a generic emitter helper.

**Emitting site**: the union destructor renderer in
`stage_10_backend` (search `_destroy(void* obj)` template /
`release_mask` construction — the record/union codegen module that builds
one `case` per constructor).

**Fix classification**: runtime-neutral if done as a compile-time-generated
static table walked by one shared loop body *per distinct field-count
shape*; otherwise leave as is — this is the lowest-value target of the four
ranked here relative to its size, mentioned for completeness since the task
explicitly asked about destructor duplication.

---

### 5. Fully-qualified module-path names inflate every one of the above

**What**: every generated struct/union/function name embeds the full
dotted module path (e.g.
`blorp_src_compiler_stage_09_core_ir__CoreExpr`,
`blorp_src_compiler_stage_10_backend_prepared_backend_renderer__PreparedBackendOp`).
This is not new/regressed behavior, but it's a force-multiplier on all of
1–4: a duplicated pop/push pair, ensure-capacity ternary, or destructor case
costs 2–4x more bytes than it would with short/interned names, because each
occurrence typically repeats one or two of these ~60–110-byte identifiers.
Not counted as its own ranked byte total (it isn't a discrete "occurrence"),
but worth flagging since it explains why the same *count* of duplicated
statements in this codebase costs more than it would elsewhere.

**Fix classification**: architectural (naming scheme / typedef aliasing),
out of scope for a text-only cleanup; not attributed bytes here to avoid
double-counting with 1–4.

## Patterns checked and found NOT to be a problem

- **Retain immediately followed by release of the same variable, adjacent
  lines**: 0 occurrences found by scripted scan of `self.c`.
- **Duplicate forward declarations of already-defined functions**: 0 in the
  single-TU `--no-embed-runtime` emission (16,959 prototypes, all unique
  names, none re-declared). The "16,959 prototypes dropped (regenerated)"
  message seen during `make` comes from `generate-build-sources`'
  8-way-split path (a different, already-deduplicating tool), not from a
  defect in `bin/blorp compile` itself.
- **Repeated `__blorp_task` re-fetch inside one function**: `void* const
  __blorp_task = __blorp_current_task;` is declared exactly once per
  function that needs it (checked all 8,106 functions that declare it) — no
  N1-style repeated task-pointer loads found in this emission mode.
- **Empty `if`/`else { }` shells, dead code after `return`**: sampled across
  the 40+ functions read; none found. `(void)((void)0);` no-op statements do
  appear (from discarded-void-body emission) but are single tokens, not
  meaningfully sized bloat.
- **List get/set inline-accessor duplication** (`__lg_list`/`__lg_idx`
  bounds-checked read, `__list_store_inline_set` bounds-checked write): real
  and visible in the `loops.brp` merge-sort sample (repeated ~10x per
  function body), but only 618–714 occurrences total in the self-compile
  itself (the compiler's own code is record/union-heavy, not
  numeric-array-heavy) — a real pattern, worth knowing about for
  numeric/list-heavy user programs, but not a top contributor to *this*
  binary's size.

## Top five to fix first

1. **Per-branch cleanup pop duplication** (finding 1, ~10.2 MB, ~10.5% of
   the file) — highest byte and runtime-work impact, but requires dataflow
   to fix safely (shared pop per post-dominator, not per source `let`).
   Start here if runtime work reduction matters as much as text size.
2. **`list_ensure_capacity`/push std-inline expansion** (finding 2, ~2.5–3
   MB) — text-only, no dataflow needed: factor into one `static inline` C
   helper. Good first PR: mechanical, low risk, immediately measurable.
3. **`__let_result_N` redundant temp** (finding 3, ~1.2 MB) — text-only,
   narrow, safe special case in `apply_let_cleanup_to_body` (emit.brp
   ~line 12805) for the "value is already a bare identifier" case. Smallest
   diff of the five, good second PR.
4. **Union destructor case boilerplate** (finding 4, ~550–650 KB) — lowest
   priority of the ranked items; only worth doing as part of a broader
   record/union codegen pass since it needs a shared per-field-count loop
   template, not a one-line fix.
5. **Audit `apply_let_cleanup_to_body`'s callers for the same "value is a
   bare identifier" shortcut** wherever else cleanup text is appended after
   a computed value (`emit_resource_scope`'s `result_name` path at
   emit.brp ~line 20684 has the identical shape) — likely another few
   hundred KB from the same root cause as finding 3, not separately
   quantified here but should be checked when finding 3 is fixed.
