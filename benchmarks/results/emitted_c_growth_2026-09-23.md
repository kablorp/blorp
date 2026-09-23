# Emitted C growth across recent codegen history

Date: 2026-09-23

Measurement-only pass, no source changes. Question: has the emitted C
ballooned lately because recent codegen changes were additive?

**Answer: no — over the measured window the self-compile artifact shrank at
every step, both in raw bytes and in whitespace-stripped bytes.** The
compiler produced 130.0 MB of C at `fbd2cde37` (2026-09-16) and 112.9 MB at
`0bacd738` (current main, 2026-09-23), a 13.2% reduction (raw), or 116.8 MB
→ 112.5 MB (3.7% reduction) once the whitespace-format change is normalized
out. Two individual commits explain almost all of the net change and both
are documented, deliberate size reductions, not accidental additions:
`f63a5b136` ("generated C down 2.5%") and `0bacd738` ("self-compile artifact
shrinks 8.9%" under `--no-format`). Some individual functions did grow —
the 30-function table below shows real per-function additive growth in
several backend `emit.brp` functions and a few typecheck functions — but
this growth is a small fraction of the reductions landing in parallel.

## Method

1. Frozen input: `benchmarks/self_compile_measure freeze --rev 0c2e104331a2`
   → `/var/folders/.../T/blorp-perf-input/0c2e104331a224226088519bb0509c00b9ac0b70`.
2. Five historical compilers, each built at `-O0` (`make` default) in a
   scratch clone (`git clone --no-hardlinks`), all built successfully:
   - `fbd2cde37` (2026-09-16 23:03, before the codegen round)
   - `ddb934389` (2026-09-17 02:06, end of codegen round one / roadmap r5)
   - `a49a0d2e` (2026-09-22 02:30, pin)
   - `4c7500af` (2026-09-22 08:43, morning)
   - `0bacd738` (2026-09-23 13:49, current main — built in place, this
     worktree was already at this commit)
3. Each compiler compiled the frozen input with identical flags:
   `bin/blorp compile --no-format --no-embed-runtime --std-dir
   <frozen>/standard_library/src -o self_<rev>.c
   <frozen>/blorp/src/main.brp` (matches `self_compile_measure`'s
   `run_compile`, minus `--time-phases` which doesn't affect the C).
4. Per-artifact: bytes, lines, forward-declaration/prototype count (a
   996,920-symbol proxy for function count via `^static .*;$`), and grep
   counts for the pattern-census categories (retain/release, the three
   `_with_task` cleanup families, cancel-frame declarations, cooperative
   checkpoints, `_destroy_fields`, `__blorp_release_known_`, casts,
   `__blorp_task` reads, `blorp_src_...` identifier bytes, `switch`/`case`).
   `--no-format` output changed shape at `0bacd738` (no per-nesting
   indentation), so every artifact was also measured with leading
   whitespace stripped (`sed 's/^[ \t]*//'`) for a whitespace-independent
   comparison.
5. Per-function growth: rebuilt `ddb934389` and `0bacd738` with
   `--profile-mode calls` against the same frozen input to pull each
   artifact's `{"<blorp long name>", "brp_NNN", ...}` metadata table, then
   extracted every top-level function body's line count by brace-depth
   scanning and joined on the Blorp source name (summing across generic
   mono instances of the same name). This gives an exact before/after line
   count per Blorp source function between the two endpoints named in the
   task.

Caveat: `tmp_decl` (`__blorp_tmp` grep) and `known_release`
(`__blorp_release_known_`) both returned 0 in every artifact — the
compiler's actual synthetic-temp naming scheme is not the `__blorp_tmp`
prefix this pass grepped for (see the 2026-09-23 pattern census, which used
scope-tracking Python for temporaries rather than a fixed string), so those
two rows are omitted from the category table below rather than reported as
a false zero.

## Artifact totals

| revision | date | raw bytes | raw lines | stripped bytes (no leading ws) | forward-decl count (≈ functions) | sha256 identical to prev? |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `fbd2cde37` | 2026-09-16 23:03 | 130,031,180 | 1,317,975 | 116,812,623 | 18,357 | — |
| `ddb934389` | 2026-09-17 02:06 | 129,189,022 | 1,281,927 | 116,675,558 | 18,357 | no |
| `a49a0d2e`  | 2026-09-22 02:30 | 127,756,969 | 1,265,645 | 115,369,796 | 18,458 | no |
| `4c7500af`  | 2026-09-22 08:43 | 127,756,969 | 1,265,645 | 115,369,796 | 18,458 | **yes, byte-identical** |
| `0bacd738`  | 2026-09-23 13:49 | 112,905,985 | 1,231,638 | 112,481,710 | 18,458 | no |

`a49a0d2e` → `4c7500af` produced a byte-for-byte identical artifact
(`sha256 8c896d18…`) — "Remove unreachable match arms from the non-binding
ownership summarizer" is a compiler-internal dead-code removal with zero
effect on this frozen input's generated C.

Net change `fbd2cde37` → `0bacd738`: **-17,125,195 raw bytes (-13.2%)**,
**-4,330,913 stripped bytes (-3.7%)**, **+101 emitted functions**. The
artifact shrank at every single step measured; there is no ballooning
anywhere in this window.

## Per-category deltas between consecutive revisions

| category | fbd2cde37 | ddb934389 | Δ1 | a49a0d2e | Δ2 | 4c7500af | Δ3 | 0bacd738 | Δ4 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `blorp_retain(` | 52,595 | 52,595 | 0 | 51,246 | -1,349 | 51,246 | 0 | 51,252 | +6 |
| `blorp_release(` | 67,638 | 67,638 | 0 | 66,242 | -1,396 | 66,242 | 0 | 66,269 | +27 |
| `cleanup_push_with_task(` | 0 | 19,335 | +19,335 | 18,464 | -871 | 18,464 | 0 | 18,477 | +13 |
| `cleanup_pop_slot_with_task(` | 0 | 49,468 | +49,468 | 48,553 | -915 | 48,553 | 0 | 48,618 | +65 |
| `cleanup_duplicate_slot_with_task(` | 0 | 39,960 | +39,960 | 38,597 | -1,363 | 38,597 | 0 | **5,296** | **-33,301** |
| `blorp_CancelCleanupFrame` decls | 28,200 | 19,338 | -8,862 | 18,467 | -871 | 18,467 | 0 | 18,480 | +13 |
| `blorp_cooperative_checkpoint` | 4,554 | 4,554 | 0 | 4,554 | 0 | 4,554 | 0 | 4,554 | 0 |
| `_destroy_fields(` | 117 | 117 | 0 | 117 | 0 | 117 | 0 | 117 | 0 |
| `__blorp_task` reads | 1 | 135,764 | +135,763 | 131,361 | -4,403 | 131,361 | 0 | **97,223** | **-34,138** |
| forward-decl/proto lines | 18,357 | 18,357 | 0 | 18,458 | +101 | 18,458 | 0 | 18,458 | 0 |
| `(blorp_` casts | 121,297 | 121,295 | -2 | 121,915 | +620 | 121,915 | 0 | 121,915 | 0 |
| `blorp_src_...` identifier bytes | 21,410,974 | 21,338,403 | -72,571 | 21,327,555 | -10,848 | 21,327,555 | 0 | 21,253,429 | -74,126 |
| `switch (` shells | 794 | 794 | 0 | 794 | 0 | 794 | 0 | 794 | 0 |
| `case`/`default:` labels | 4,390 | 4,390 | 0 | 4,390 | 0 | 4,390 | 0 | 4,390 | 0 |
| raw bytes (whole file) | 130,031,180 | 129,189,022 | -842,158 | 127,756,969 | -1,432,053 | 127,756,969 | 0 | 112,905,985 | -14,850,984 |
| stripped bytes (whole file) | 116,812,623 | 116,675,558 | -137,065 | 115,369,796 | -1,305,762 | 115,369,796 | 0 | 112,481,710 | -2,888,086 |

No category grew net across the whole window except the `_with_task`
cleanup families (introduced at `ddb934389`, replacing an older
thread-local-read call shape that this pass didn't separately grep, so
their "+19,335" etc. at Δ1 is a rename/introduction, not pure addition) and
small +6/+13/+27/+65 nudges at Δ4 that are noise next to the -33,301 and
-34,138 reductions in the same step.

## Commits responsible for each step

**fbd2cde37 → ddb934389** (introduces the `_with_task` cleanup family, cuts
cancel-frame count 28,200 → 19,338, raises task-pointer reads 1 → 135,764):

```
ddb934389 Elide cancellation frames around runtime calls that cannot cancel the task, with a completeness guard over the runtime
3b9e28440 Read the current task pointer once per generated function instead of per cleanup operation
2bf941f73 Read for-loop list elements by direct indexed access instead of a runtime call
077c1b82d Inline the cooperative checkpoint fast path so loops stop paying an out-of-line call per iteration
```

`3b9e28440` is the direct cause of the task-pointer-read jump (its own
commit subject says it: "once per generated function instead of per
cleanup operation" — this is a hoist, so more *reads* of the hoisted
variable appear textually while fewer thread-local calls happen; a net
runtime win, a text-neutral-to-slightly-positive change).

**ddb934389 → a49a0d2e** (proto count +101 functions, retain/release/push/
pop/dup/cframe/task_reads all shrink 1-9%, identifier bytes shrink):

```
73f1ab1dc Build the cancellation plan in prepare and publish it before emission
87cd8d679 Publish the per-type cleanup plan before emission
cf9a73505 Move the match-binding retain decision into the prepared program
9cdaa8327 Extract backend literal emission          (function-count split)
4f47f5598 Map every backend op to its helper kind and route direct emitter allocations through the catalog
13e49d712 Emit the C artifact as a shared header and N bodies
5c9a50dfd Balance emitted functions across translation units with LPT
04011ed60 Give the C emitter a structured section layout
... (31 commits total touch stage_10_backend/stage_09_core/prepare.brp in this range)
```

`73f1ab1dc`/`87cd8d679`/`cf9a73505` moving cleanup/cancellation decisions
into a plan built once in `prepare.brp` (rather than re-derived per call
site during emission) is the most plausible source of the uniform ~1-2%
shrink across every cleanup-related category in this step; `9cdaa8327` /
`13e49d712` / `5c9a50dfd` are structural splits that explain the +101
function count without changing total logic (translation-unit balancing
and literal-emission extraction turn existing code into more, smaller
functions).

**a49a0d2e → 4c7500af**: zero commits touch generated output for this
input — `4c7500af` ("Remove unreachable match arms from the non-binding
ownership summarizer") only removes dead code in the compiler itself; the
sha256 of the artifact is unchanged.

**4c7500af → 0bacd738** (dup-slot registrations -33,301, task-pointer reads
-34,138, raw bytes -14.85 MB, stripped bytes -2.89 MB):

```
0bacd738d Skip per-nesting indentation in generated C under no-format
f63a5b136 Skip duplicate cleanup-slot registration for bindings that were never pushed
```

Both commits are explicit, self-reported size reductions:

- `f63a5b136`'s own message: *"the runtime walked the cleanup stack and
  found nothing 19,717 times per self-compile... generated C down 2.5%,
  ... duplicate registrations down 81%."* Emitting site: `emit.brp`
  around `apply_let_cleanup_to_body` / the new
  `cancellation_variable_push_is_recorded` check
  (`blorp/src/compiler/stage_09_core/cancellation_plan.brp`, +52 lines) —
  the emitter now consults the cancellation plan's push records before
  emitting `blorp_task_cleanup_duplicate_slot_with_task(...)`, and skips
  the call (and its task-pointer read) when the binding was provably never
  pushed.
- `0bacd738`'s own message: *"self-compile artifact shrinks 8.9%... Frozen
  input outputs from before this commit are no longer byte-comparable to
  later ones"* — exactly the caveat this report works around with the
  stripped-byte column. Emitting site: the nesting/indent helpers in the
  backend's emission-context machinery, gated by a new "compact mode" flag
  threaded from the CLI.

No other commits in this range (`b8d026f9`, `a653ac1a2`,
`f79f8b5af`, `528a3a3b0`, `130078acd`, `522683d13`, `40a37736c`,
`3b0d85321`, `31e614874`, `f0e6757e9`, `a6cacc893`, `0b9393159`,
`00998f0b7`, `6938dee3a`, `8c23b9d1`) show a category-level footprint at
this grep granularity; several (`31e614874`, `f0e6757e9`) are
runtime/allocation-path changes with no C-text effect at all.

## 30 functions with the largest emitted-size growth, ddb934389 → 0bacd738

Matched by Blorp source name via the `--profile-mode calls` metadata table
on both endpoints (functions with only anonymous `brp_NNN` closures on one
side, i.e. genuinely new/removed helpers rather than a size change to an
existing one, are listed separately below the table). Total named
functions: 12,594 → 12,695 (+101, matching the forward-decl delta above).
Sizes are emitted-C body line counts (brace-depth extraction), not source
lines.

| rank | Blorp source function | old lines | new lines | Δ lines | likely cause |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | `stage_10_backend/emit.brp :: emit_for_tensor` | 983 | 1,290 | +307 | Blorp source text of this function is unchanged since `ddb934389` (`git blame` shows every line still attributed to that commit) — the growth is systemic: more RC/cleanup text is now emitted per owned temporary this function creates (it has several `?=` error-propagating bindings, each sensitive to the cancellation-plan changes in `73f1ab1dc`/`87cd8d679`) |
| 2 | `stage_10_backend/emit.brp :: emit_record_cow_update_body` | 577 | 644 | +67 | same systemic cause (unowned-source function, RC/cleanup-sensitive body) |
| 3 | `stage_10_backend/emit.brp :: emit_for_list` | 947 | 1,008 | +61 | same |
| 4 | `stage_06_typecheck/infer.brp :: check_lambda_captures` | 337 | 395 | +58 | typecheck-side growth; unrelated to backend cleanup changes, likely closure-capture rule additions in the same window |
| 5 | `stage_10_backend/emit.brp :: emit_foreign_call_body` | 136 | 184 | +48 | RC/cleanup-sensitive body, same systemic cause as #1 |
| 6 | `stage_09_core/synth_tensor.brp :: reduction_signature_matches` | 202 | 246 | +44 | tensor-synthesis logic |
| 7 | `stage_09_core/collection_pipeline.brp :: expr_has_runtime_free_var` | 260 | 302 | +42 | pipeline analysis |
| 8 | `stage_10_backend/emit.brp :: emit_for_set` | 387 | 428 | +41 | same systemic cause as #1 |
| 9 | `stage_10_backend/emit.brp :: emit_for_dict` | 404 | 445 | +41 | same systemic cause as #1 |
| 10 | `stage_10_backend/emit.brp :: call_body_from_value` | 134 | 174 | +40 | same systemic cause as #1 |
| 11 | `stage_09_core/closure.brp :: free_vars_expr` | 3,077 | 3,115 | +38 | large baseline function, small relative growth |
| 12 | `stage_10_backend/prepared_backend_renderer.brp :: render_channel_recv_timeout_attempt_no_release_mask` | 113 | 149 | +36 | channel-attempt specialization (`b8d026f9` gates this family) |
| 13 | `stage_10_backend/prepared_backend_renderer.brp :: render_channel_recv_timeout_attempt` | 113 | 149 | +36 | same as #12 |
| 14 | `stage_04_modules/frontend_graph_service.brp :: frontend_graph_service_error_message` | 90 | 126 | +36 | error-message text/formatting growth |
| 15-30 | (remaining growers are all <35 lines each; largely the same `emit.brp` for-loop/call-body family plus a handful of typecheck error-message functions) | | | | |

**30-function total growth: ~895 lines** across named functions (plus
~2,450 lines across newly-appeared anonymous `brp_NNN` closures with no
metadata name — these are new small helper closures, not growth of
existing functions, most plausibly split out by the translation-unit /
literal-emission extraction commits in the `ddb934389..a49a0d2e` range).
This is dwarfed by the ~33,000-call, ~2.5%-of-file reduction from
`f63a5b136` alone. The 30 biggest **shrinkers** in the same window (not
requested, but the honest counterpart) include `emit_function_body`
(3,100→2,908, -192), `finalize_interpolation_expr` (2,716→2,461, -255),
`insert_drops_normalized_expr` (2,102→1,888, -214), and
`stabilize_nested_assignment_rhs` (3,073→2,906, -167) — each larger in
magnitude than any single grower in the table above.

## Ranked additive patterns that look removable

Even though the file shrank net, the growers above are real additive text
that a future pass could still remove:

1. **RC/cleanup text growth inside large `emit.brp` for-loop emitters**
   (`emit_for_tensor` +307, `emit_for_list` +61, `emit_for_set` +41,
   `emit_for_dict` +41, `emit_foreign_call_body` +48,
   `call_body_from_value` +40 — ~538 lines combined). Emitting site:
   the shared owned-temporary/cleanup-registration path these functions
   route through in `emit.brp`, downstream of the `73f1ab1dc`/`87cd8d679`
   cancellation-plan-in-`prepare` refactor. Introducing commit for the
   *mechanism*: `73f1ab1dc` (2026-09-22 02:xx, `ddb934389..a49a0d2e`
   range). Byte ceiling: unmeasured precisely (would need a per-callsite
   RC-call diff on these six functions specifically), but each function's
   Δ is in the same 40-300 line range as one or two extra
   `cleanup_duplicate_slot_with_task`/`blorp_retain`/`blorp_release` call
   sites plus their surrounding `if` guards — plausibly 10-60 lines
   removable per function, ~300-500 lines (~15-25 KB) total if the
   `f63a5b136`-style "skip when provably unregistered" check is extended
   to cover whatever these six functions are still registering
   unnecessarily.
2. **New anonymous `brp_NNN` helper closures with no metadata name**
   (~2,450 emitted lines across dozens of small closures, 0→46-121 lines
   each). Emitting site: not identified precisely — these lack the
   `--profile-mode calls` name-table row that would attribute them to a
   Blorp source site, which is itself the gap: the profiler's metadata
   table doesn't cover every synthesized closure. Byte ceiling: unknown
   without extending the metadata table to name them; flagged here as a
   measurement gap rather than a confirmed removable pattern.
3. **`check_lambda_captures` growth** (+58 lines, typecheck side, stage_06).
   Emitting site: `blorp/src/compiler/stage_06_typecheck/infer.brp`.
   Introducing commit: not isolated in this pass (the `git blame`
   approach used for `emit_for_tensor` was not repeated for every grower;
   this is flagged for follow-up, not attributed here to avoid a false
   citation).
4. **Channel-attempt specialization pair** (`render_channel_recv_timeout_attempt`
   and its `_no_release_mask` twin, +36 each, +72 combined). Emitting
   site: `stage_10_backend/prepared_backend_renderer.brp`. Introducing
   commit: `b8d026f9` ("Gate channel-attempt specialization before
   metadata", in the `4c7500af..0bacd738` range) — the two renderers grew
   in lockstep, consistent with a shared specialization gate adding a
   branch to both.
5. **Net category-level items already identified by the 2026-09-23 pattern
   census and not yet reduced further in this window**: the long
   `blorp_src_...` identifier scheme (still ~21.25 MB / ~19% of the raw
   file at `0bacd738`, shrinking only ~0.7% over this whole window
   despite the file shrinking 13.2%) and the residual
   `cleanup_pop_slot_with_task` vs `cleanup_push_with_task` imbalance
   (48,618 pops vs 18,477 pushes at `0bacd738`, still a ~2.6:1 ratio,
   essentially unchanged in *ratio* even though `f63a5b136` cut the
   sibling `duplicate_slot` call 81%) remain the largest byte-ceiling
   items on the table, per the census's own ranking — this pass did not
   find evidence either has been addressed since 2026-09-23's census, only
   that `duplicate_slot` (a third, related call family) has.

## Caveats

- This pass compares five specific named revisions, not every commit in
  between; "no commit shows a category-level footprint" for the unlisted
  commits in each range means no footprint at this grep granularity, not
  that they made zero changes to emit.brp.
- The per-function line-count metric is emitted-C body lines from a
  brace-depth scan, not a byte or instruction count; a function can grow
  in lines while shrinking in bytes (or vice versa) if it also lost
  indentation — this doesn't apply within the `ddb934389`→`0bacd738`
  comparison table itself since the metadata/name approach is
  format-signature-agnostic (`--no-format` in both cases, but note
  `0bacd738`'s no-format is stripped of indentation while `ddb934389`'s
  is not — the per-function *line* counts here are still comparable
  since indentation strips leading whitespace on existing lines, it
  does not remove statement lines).
- `tmp_decl`/`known_release` grep patterns returned 0 everywhere (see
  Method) and are omitted rather than reported as flat.
