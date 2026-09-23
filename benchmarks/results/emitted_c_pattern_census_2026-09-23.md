# Emitted C pattern census

Date: 2026-09-23

Compiler commit: `67d954c6fa9f644855e008c94c4eea0c420ecf2a` (`origin/main`,
clean). Toolchain: `bin/blorp --version` reports `target: aarch64-apple-darwin`,
`cc: Apple clang version 21.0.0 (clang-2100.3.34.2)`, `optimization: cli=-O2
runtime=-O2`, 8-way split build. This is a measurement pass only: no source
changes.

## Method

1. `make` with `BLORP_CLI_C_OPTIMIZATION=-O2`; `scripts/compiler-build-status`
   confirmed FRESH.
2. `bin/blorp compile --no-embed-runtime --no-format -o self.c
   blorp/src/main.brp` — the self-compile artifact this census reads.
   `self.c`: **111,406,045 bytes, 1,577,401 lines**.
3. `bin/blorp compile --profile-mode calls --no-embed-runtime --no-format -o
   prof.c blorp/src/main.brp` to pull the `{"blorp_..._function_name",
   "brp_NNN", "module/path", id, flags}` metadata table out of the generated
   C, giving a `brp_NNN -> Blorp source name` map without running anything
   (14,639 mapped entries; the rest are anonymous/closure-shaped `brp_`
   symbols with no logical-function metadata).
4. Pattern counts and byte totals below come from `grep -c` / `grep -o | wc`
   for single-token patterns, and small Python scripts (kept in the shell
   history of this run, not committed) for anything that needs scope
   tracking: matching a function's `{`/`}` depth to measure its body, or
   counting a synthetic identifier's occurrences within the one function
   that declared it. Byte counts for a pattern are the byte length of the
   **matching lines**, not just the matched substring, since one line is
   usually one emitted statement; where a pattern's own token length is what
   matters (identifiers), the token bytes are called out separately and
   flagged as cross-cutting (see the note under category 6).
5. Function boundaries: the backend gives every emitted top-level function a
   synthetic name `brp_NNN` (base-36-ish suffix, e.g. `brp_3Od`, `brp_5UW`);
   every one of the 16,920 distinct `brp_*` symbols in the file has exactly
   one `static ... brp_NNN(...);` prototype and exactly one `... brp_NNN(...)
   {` definition (confirmed: prototype count, unique symbol count, and
   `{`/`}`-balanced definition count are all 16,920). Prior census reports
   (`docs/PER_NODE_CODEGEN_ROADMAP.md`, main `fbd2cde37`, 97 MB / 1.42M lines
   / 15,141 functions) used the same convention; the artifact has grown
   ~16.9 MB / 157K lines / 1,779 functions since then.

Caveat on overlap: categories 1-5 and 8-9 are close to a mutually exclusive
line partition (a line rarely matches two of them). Categories 6 (identifiers)
and 7 (temporaries) are **cross-cutting** — a `blorp_retain(node)` line inside
a cleanup-frame block contains an identifier and may reference a temporary,
so its bytes are already counted once in category 1, and the identifier/
temporary numbers describe a property of text that is scattered across every
other category, not a disjoint slice of the file. The byte-share table
adds up to about 100% only when 6 and 7 are read as overlays, not additions.

## Artifact totals

| metric | value |
| --- | ---: |
| total bytes | 111,406,045 |
| total lines | 1,577,401 |
| distinct emitted functions (`brp_NNN` symbols) | 16,920 |
| sum of function-body lines (defs only, excl. prototypes) | 1,403,389 |
| average lines per function | 82.94 |
| named destructor functions (`..._destroy(void* obj)`) | 2,063 (separate from the `brp_` family; own name) |

### Top 20 largest emitted functions by lines

| rank | symbol | lines | Blorp source name |
| ---: | --- | ---: | --- |
| 1 | `brp_5UW` | 40,716 | `blorp_src_lib_cli_args__parse_package_args` |
| 2 | `brp_4L4` | 7,660 | `blorp_src_compiler_stage_09_core_synth_list__synthesize_named_body` |
| 3 | `brp_4aT` | 6,946 | `blorp_src_compiler_stage_09_core_perceus_mutable__rewrite_mutable_assignments` |
| 4 | `brp_4aH` | 4,739 | `blorp_src_compiler_stage_09_core_perceus_mutable__stabilize_nested_assignment_rhs` |
| 5 | `brp_47n` | 3,827 | `blorp_src_compiler_stage_09_core_perceus_borrowed__normalize_borrowed_boundaries` |
| 6 | `brp_4bk` | 3,645 | `blorp_src_compiler_stage_09_core_perceus_protect__protect_repeated_consumes_impl` |
| 7 | `brp_5e8` | 3,478 | `blorp_src_compiler_stage_10_backend_emit__emit_function_body` |
| 8 | `brp_4DX` | 3,225 | `blorp_src_compiler_stage_09_core_std_inline__clone_expr` |
| 9 | `brp_35O` | 3,118 | `blorp_src_compiler_stage_09_core_closure__free_vars_expr` |
| 10 | `brp_7Vy` | 2,769 | `blorp_src_compiler_stage_09_core_traverse__map_core_storage_children_with_state` (mono: `CoreMatchCloneState`) |
| 11 | `brp_7VG` | 2,769 | same generic function, mono: `StdInlineRewriteState` |
| 12 | `brp_7VP` | 2,769 | same generic function, mono: `TupleSroaTraversalState` |
| 13 | `brp_37K` | 2,748 | `blorp_src_compiler_stage_09_core_closure__convert_storage_expr` |
| 14 | `brp_7Vq` | 2,529 | same generic function, mono: `Int` |
| 15 | `brp_3dC` | 2,498 | `blorp_src_compiler_stage_09_core_dce__collect_expr_children` |
| 16 | `brp_9h` | 2,365 | `blorp_src_compiler_stage_02_lex_lexer__lex` |
| 17 | `brp_4Nw` | 2,339 | `blorp_src_compiler_stage_09_core_synth_string__synthesize_named_body` |
| 18 | `brp_37M` | 2,265 | `blorp_src_compiler_stage_09_core_closure__convert_loop_expr` |
| 19 | `brp_401` | 2,264 | `blorp_src_compiler_stage_09_core_ownership_contracts__schedule_contract_linear` |
| 20 | `brp_u6` | 2,233 | `blorp_src_compiler_stage_03_parse_source_ast_finalize__finalize_interpolation_expr` |

Rank 1 alone is 40,716 lines — **2.9% of every function-body line in the
compiler in one function**. It is `parse_package_args`, presumably a large
CLI-flag match/dispatch. Ranks 10, 11, 12, 14 are the same generic function
(`map_core_storage_children_with_state`) monomorphized four times, at 2,769,
2,769, 2,769, and 2,529 lines each (11,836 lines total for one generic
definition) — a mono-bloat data point, not a per-node pattern, but relevant
to "what's large" for whoever looks at this table next.

## Pattern counts by category

| # | category | occurrences | bytes | % of file | emitting function family (`emit.brp`) |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | Reference counting | see below | 9,372,616 | 8.41% | `emit_dup_statement` (~12803), `emit_release_statement` (~12208), per-field carry retain (~10145), `emit_release_aware_*_dict_constructor_call` (~6705-6720) |
| 2 | Cleanup frames and slots | see below | 13,032,328 | 11.70% | `cancellation_cleanup_push_statement`/`_pop_statement` (~12488-12513), `owned_temp_cleanup_push/pop_statement` (~12341-12460), `planned_*_cleanup_push/pop_statement` (~12374-12447), `select_cleanup_push/pop_statement` (~16081-16105), `cleanup_frame_name` (~2582) |
| 3 | Cooperative checkpoints | 5,290 | 236,690 | 0.21% | loop-arm emission in the `for`/`while` renderer (see N5 in the roadmap; fast path already inlined at the runtime level, this is the remaining out-of-line call text, one per loop site) |
| 4 | Destructors | see below | 1,439,021 | 1.29% | `emit_heap_record_destructor` (~24582), `emit_union_destructor` / `emit_iterative_union_destructor` / `emit_simple_union_destructor` (~24852-24936) |
| 5 | Forward declarations and prototypes | 16,920 | 2,316,986 | 2.08% | `emit_function_forward_decl` / `emit_function_forward_decls` (~22344, ~25607) |
| 6 | Type definitions and identifiers | see below | 1,257,582 (defs) + 26,836,165 (identifier text, cross-cutting) | 1.13% + 24.09%\* | struct/union layout in `emit_record_layout.brp`; identifier construction in the naming helpers `c_var_name`/`c_local_name`/`c_identifier` (see `backend_emission_attribution_2026-09-23.md`) |
| 7 | Temporaries | 372,657 distinct per-scope, 166,691 single-use | ~5-28 MB depending on what's counted (see below), cross-cutting | ~4.5-25%\* | `temp_name()`, `nested_emission_context()`, `emit_simple_expr`/`_bounded`/`_leaf` (see `backend_emission_attribution_2026-09-23.md`) |
| 8 | Match/decision-tree scaffolding | 14,036 trap blocks + 800 switches + 4,424 case/default labels | 2,195,946 | 1.97% | non-exhaustive trap: emit.brp ~19651; `switch`/`case` shells: the `CoreLiteral` match and enum-dispatch renderers |
| 9 | Whitespace and indentation | 1,577,401 newlines + leading indent | 16,552,407 | 14.86% | `nested_emission_context` (indent string rebuilt per nesting level, ~272,787 calls per the emission-attribution report) |
| 10 | Everything else (real function-body work) | — | 61,328,695 (residual) | 55.05% | — |

\* Categories 6 and 7 overlap with 1-5, 8, 9 and with each other (identifiers
appear inside RC calls, cleanup calls, struct fields, prototypes, and plain
function-body code; temporaries are declared and read inside all of those
too). Their bytes are not additional file bytes on top of the other rows;
they describe how much of the *already-counted* text is "a long identifier"
or "a single-use scratch variable." The percentages in rows 1-5, 8, 9 sum
with row 10 to close to 100% on their own (8.41+11.70+0.21+1.29+2.08+
1.13+1.97+14.86+55.05 ≈ 96.7%, the remainder being small categories not
broken out, e.g. `#include`/typedef-forward lines and file-level boilerplate).

### Reference counting detail

| pattern | occurrences | bytes |
| --- | ---: | ---: |
| `blorp_retain(` | 63,788 | 4,694,456 |
| `blorp_release(` | 85,150 | 3,976,339 |
| `blorp_release_arc_only(` | 1,743 | 124,643 |
| `blorp_list_retain_for(` (append with a retained element) | 5,196 | 577,178 |
| `blorp_move_ref(` | 0 | 0 |

`blorp_move_ref` does not exist in the current emitter — N6 ("move a local on
its last use instead of dup and drop") and N7 cut 2 (match-binding iterables)
were dropped/parked as flat in the first codegen round, and nothing since has
introduced a move form. Every consuming use still pays a retain-then-release
pair. The retain:release ratio is roughly 3:4, consistent with the roadmap's
description of retain/release as the largest reference-counting share (this
is a byte census, not the earlier instruction-sampling profile, but the
shapes agree).

### Cleanup frames and slots detail

| pattern | occurrences | bytes |
| --- | ---: | ---: |
| `blorp_task_cleanup_push_with_task(` | 27,877 | 4,869,824 |
| `blorp_task_cleanup_pop_slot_with_task(` | 72,168 | 5,551,588 |
| `blorp_task_cleanup_duplicate_slot_with_task(` | 9,101 | 674,012 |
| `blorp_CancelCleanupFrame` declarations | 27,878 | 1,936,904 |

All three call families now use the `_with_task` variants — N1 ("read the
task pointer once per function") landed and every cleanup site takes the
hoisted pointer instead of reading the thread-local per call, matching the
roadmap's plan. Two things have **not** changed since the roadmap's last
snapshot: pops (72,168) still outnumber pushes (27,877) by **2.6x**, the
exact "every exit path re-emits the pops for the frames still open" pattern
N8 named — some frame elision has clearly landed (28k `CancelCleanupFrame`
declarations here vs. 29,852 push/pop pairs and 7,385 frame-bearing functions
in the roadmap's earlier count, so raw frame count is roughly flat while the
compiler has grown ~12% in lines), but the pop multiplication survives it.
`blorp_task_cleanup_duplicate_slot_with_task` at 9,101 is far below the
roadmap's original 44,782 duplicate-slot count — N7 cut 1 (borrowed
parameters/lets) landed and evidently removed most of that mass.

### Destructors detail

| pattern | occurrences | bytes |
| --- | ---: | ---: |
| named `..._destroy(void* obj)` functions | 2,063 | 1,414,205 |
| `..._destroy_fields(` calls | 111 | 24,816 |
| `blorp_union_destroy_stack_grow(` (iterative union destructor worklist growth, one call site per union type) | 38 | not separately measured, small |
| `__blorp_release_known_*` | 0 | 0 |

The iterative union destructor (mentioned in the read-first list as a recent
landing) shows up as the `_destroy_stack_grow` worklist helper generated once
per recursive union type rather than deep native recursion; it is a small,
flat per-type cost (a stack struct + a grow call), not a per-node cost, so it
does not show up as a large byte category even though it changed the
destructor's *shape*.

### Match/decision-tree scaffolding detail

| pattern | occurrences | bytes |
| --- | ---: | ---: |
| non-exhaustive-match trap block (`} else { fprintf(...); abort(); }`) | 14,036 | 1,768,452 |
| `switch (` shells | 800 | 16,988 |
| `case ` / `default:` labels | 4,424 | 362,810 |
| `break;` | 4,336 | ~47,700 |

No `goto` anywhere in the artifact (`grep -c 'goto '` = 0) — every union
match compiles to an `if`/`else if`/`else` chain (see the code sample in
`docs/PER_NODE_CODEGEN_ROADMAP.md`'s Pattern C), not a jump table, and the
"labels" that showed up in an early grep pass turned out to be `default:`
inside the 800 `switch` shells (used for literal/enum dispatch), not
control-flow labels.

## Ranked: five categories with the largest byte share, plausibly reducible

1. **Long qualified identifiers (`blorp_src_...` names).** ~26.8 MB, 24.1% of
   the file — the single largest byte category found, larger even than the
   whitespace category. 437,321 occurrences average 61.4 bytes each
   (`blorp_src_compiler_stage_09_core_perceus_mutable__rewrite_mutable_assignments`-style
   dotted-module-path names baked into every type name, cast, and call).
   *Mechanism*: shorten — give every type and function a short stable name
   (the compiler already does exactly this for functions via the `brp_NNN`
   scheme; the missing piece is doing the same for **type** names, which
   still carry the full module path) and keep the human-readable name in the
   side table the profiler already emits (the `{"long_name", "short_name",
   ...}` metadata array proven out by `--profile-mode calls`). *Evidence*: an
   almost-identical scheme already exists and is load-bearing for functions;
   only struct/union typedef names were left long. *Byte ceiling*: cutting
   average identifier length from 61.4 to something in the 10-15 byte range
   (comparable to `brp_NNN`) removes roughly 20 MB, ~18% of the file.
   *Runtime effect*: none — text only; same symbols after `cc` resolves
   them, though shorter names measurably speed up `cc`'s own lexing on a
   111 MB translation unit.

2. **Whitespace and indentation.** 16.55 MB, 14.86% of the file (14.97 MB
   leading indentation + 1.58 MB newlines) even with `--no-format`.
   *Mechanism*: hoist/share — `nested_emission_context` (272,787 calls per
   the emission-attribution report) allocates a fresh, one-longer indent
   string on every nested scope entry; the text cost is the flip side of
   that allocation cost. A depth-indexed table of precomputed indent strings
   (already proposed and rejected on allocation-count grounds in the
   emission-attribution report) would cut the bytes without touching
   semantics, or the backend could simply cap indent growth past a shallow
   depth, since deeply nested emitted blocks are already visually
   unreadable in the unformatted artifact. *Evidence*: 1,577,401 lines each
   carry at least one indentation run; average leading whitespace is 9.5
   bytes/line site-wide. *Byte ceiling*: capping indentation at, say, 4
   levels (8 spaces) instead of unbounded growth would remove a large
   fraction of the 15 MB, likely several MB; a precise ceiling needs a
   histogram of indent depth this pass did not build. *Runtime effect*:
   none — text only.

3. **Cleanup frames and slots, specifically the pop:push imbalance.** 13.03
   MB total, 11.70% of the file; of that, `pop_slot_with_task` alone is 5.55
   MB against 4.87 MB for `push_with_task`, a 2.6x count ratio the roadmap's
   N8 task already diagnosed as "every exit path re-emits the pops for the
   frames still open." *Mechanism*: share — one shared exit block (or a
   single `__attribute__((cleanup))` per frame instead of manually
   re-emitted pops on every `return`/`break`/error path) collapses the
   duplicate pop text without changing release order. *Evidence*: direct
   count, unchanged in shape since the roadmap's diagnosis; this document's
   fresh count (72,168 pops / 27,877 pushes) shows the ratio persists after
   two intervening frame-elision-adjacent landings (`f63a5b13`, the frame
   work referenced in N8's "landed" row). *Byte ceiling*: collapsing to
   near 1:1 would remove roughly (72,168-27,877) x ~64 bytes/call ≈ 2.8 MB.
   *Runtime effect*: text and instructions both — fewer duplicate pop calls
   is fewer branches executed per exit path, a genuine per-node cost
   reduction, not just a text saving (this is the one item on this list
   that changes runtime work, matching N8's own framing).

4. **Single-use synthetic temporaries.** Of 372,657 distinct `__`-prefixed
   synthetic identifiers counted within the one function scope that declares
   each of them, 166,691 (44.7%) occur exactly twice in that scope: once at
   declaration, once at the single read. *Mechanism*: elide — substitute the
   initializer expression directly at the one use site instead of naming it,
   the backend-only (no Perceus/ownership change) version of the pattern
   N6/N3 tried and found flat at the instruction level; here the target is
   text, not ownership, so the two do not compete for risk budget.
   *Evidence*: direct per-function-scope count; families like
   `__match_scrut_N` are 85% single-use by variable count in the earlier
   (buggy, cross-function) global tally and the corrected per-scope number
   confirms the shape holds broadly, not just for one family. *Byte
   ceiling*: a 2,000-line sample of `Type* __name = expr;`-shaped
   declarations averages 166 bytes/line; removing the declaration statement
   and its wrapper text (not the relocated expression, which still has to
   live somewhere) is closer to 30-40 bytes/site, so roughly 166,691 x 35
   bytes ≈ 5.8 MB is the realistic ceiling, not the naively multiplied
   ~28 MB. *Runtime effect*: none if done as a pure peephole after ownership
   is already decided — one fewer local and one fewer store, arguably a
   small instruction win too, but the byte case does not depend on it.

5. **Forward declarations and prototypes.** 2.32 MB, 2.08% of the file,
   16,920 entries — smallest share of the five, but the cleanest case: 10,298
   of them (60.9%) are for functions whose own definition appears in the
   file *before* the first call site that could need the forward reference,
   measured directly (definition line number less than the second occurrence
   of the symbol, i.e. no call between the prototype and the definition).
   *Mechanism*: elide — only emit a prototype when a call site precedes the
   definition, or order definitions so mutual/forward references are the
   exception rather than assumed for all 16,920 functions uniformly.
   *Evidence*: this document's direct measurement, not an inference; the
   remaining 39.1% presumably do need the forward declaration for genuine
   mutual recursion or definition-after-use ordering. *Byte ceiling*: 1.48
   MB, the exact byte size of those 10,298 lines. *Runtime effect*: none —
   text only, same symbols, same call sites.
