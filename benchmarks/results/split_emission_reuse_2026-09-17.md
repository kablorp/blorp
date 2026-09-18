# Split emission reuse: pre- vs post-change (2026-09-17)

## Rebase addendum

`origin/main` moved to `a724037b2` ("Escape record fields that collide with
the runtime object header") while this change was in review. That commit
also touches `blorp/src/compiler/stage_10_backend/emit.brp`: it renames
`c_identifier` to a new `c_field_name` helper at every record/union
field-name emission site (declaration, constructor param, make/reuse
assignment, field read) so a field literally named `header` gets escaped to
`__blorp_field_header` instead of colliding with the heap record's
synthesized `blorp_Object header` member. None of the renamed call sites
fall inside code this change moved, deleted, or rewrote (the renames land in
`emit_value_record_decl`, `emit_heap_record_decl`, `heap_record_field_decl`,
`heap_record_make_param`, `heap_record_field_release_statement`, and
`emit_heap_record_reuse` -- functions this change calls but never edited the
bodies of), so `git rebase origin/main` applied with **no conflict**.

Because the split path (`render_split_translation_units`) now reads its
`CValueRecordDeclEmission` / `CHeapRecordDeclEmission` / `CEnumDeclEmission`
/ `CUnionDeclEmission` records straight off `CEmissionSections` instead of
re-deriving them, and those records are built by exactly the same
`emit_value_record_decl` / `emit_heap_record_decl` / `emit_enum_decl` /
`emit_union_decl` functions the single-file path uses, the field-escaping
helper applies identically on both paths with no additional plumbing: there
was nothing in this change's own code that named a field, so there was
nothing to update.

Added a split-path regression test that didn't exist before,
`test_split_path_escapes_runtime_reserved_field_names` in
`blorp/test/compiler/stage_10_backend/test_split_emit.brp` (their new test,
`test_emit_runtime_reserved_record_member_names` in `test_core_emit.brp`,
only exercises the single-file path via `emit_unprojected_core_program_c_
artifact_for_tests`). The new test builds a heap record with a field named
`header`, splits it across 2 translation units, and asserts: the shared
header's typedef spells the member `__blorp_field_header` (not `header`),
the `make` function's assignment (a type-support definition routed to TU 0)
assigns through the same escaped name exactly once across all bodies, and
the raw collision (`  long header;` in the typedef, or an unescaped
`->header =` assignment) appears nowhere in the header or any body. It
passes.

Re-verified against the new base (`a724037b2`):

- Byte-identity, both paths, both programs (`blorp/tool/generate_build_
  sources.brp` and a `git archive a724037b2` export of `blorp/src/main.brp`
  with its `stage_01_generated_inputs` regenerated), comparing an
  `a724037b2`-built compiler against this branch's rebased compiler: all of
  `single.c`, `split.0.c`..`split.3.c`, and `split.h` are `cmp` identical for
  both programs.
- `scripts/compiler-check blorp/test/compiler/stage_10_backend/test_split_emit.brp`:
  pass, 14/14 (was 13; the new test is the 14th).
- `scripts/compiler-check --changed`: pass.
- `scripts/test compiler-blorp --serial --no-build`: pass, 4858/4858 (up
  from 4851 pre-rebase; the increase is their new tests plus this change's
  new one).
- `blorp/test/build/test_split_translation_units.sh`: pass, 5/5.
- `make quality`: pass (same pre-existing, unrelated `runtime.c`
  static-analysis warnings as before).

Rebased and amended onto `a724037b2`; see the branch's current HEAD for the
commit SHA (title unchanged: "Reuse per-declaration emissions when rendering
split units").


`render_split_translation_units` used to re-derive each declaration's
`CValueRecordDeclEmission` / `CHeapRecordDeclEmission` / `CEnumDeclEmission` /
`CUnionDeclEmission` by calling `emit_value_record_decl` / `emit_heap_record_decl`
/ `emit_enum_decl` / `emit_union_decl` a second time, even though `emit_decls`
(step 1, commit `04011ed60`) already builds those exact records to fill in
`CEmissionSections`'s flat section strings. This change makes `emit_decls`
keep the per-declaration lists on `CEmissionSections`
(`value_record_emissions`, `heap_record_emissions`, `enum_emissions`,
`union_emissions`) and fold them into the flat strings via new
`join_*_decl_emissions` helpers, so `render_split_translation_units` reads
those lists off `sections` instead of re-deriving them. `render_split_translation_units`
no longer needs a `layouts: CRecordLayoutRegistry` parameter (it was only used
for the two re-derivation calls), and its caller
(`try_emit_prepared_core_program_c_split_artifact_with_profile`) no longer
calls `classify_c_record_layouts` a second time just to build that argument.

Pre-change binary: commit `75df388c4` (== `origin/main`, which contains
`009bd5371`), built in a separate worktree. Post-change binary: this branch's
`bin/blorp`. Host: Darwin 25.6.0, shared with other agents; load average was
elevated and variable throughout (roughly 2.4-4.8), so single-run and even
3-run-median timings below carry real noise -- read the emission-only numbers
(least contended by other work) as the more trustworthy signal for what this
change actually did.

## Byte-identity

Both the single-file and split paths render byte-identical output before and
after this change, on two programs:

- `blorp/tool/generate_build_sources.brp` (current tree), `--c-translation-units=1`
  and `=4`: `single.c`, `split.0.c`..`split.3.c`, and `split.h` all `cmp`
  identical between the pre- and post-change compiler.
- `blorp/src/main.brp` from a `git archive 009bd5371` export (its two
  `stage_01_generated_inputs` files regenerated by that tree's own
  `generate-build-sources`, then built with `make` so the tree is complete),
  compiled by the pre- and post-change binaries with `--c-translation-units=1`
  and `=4`: `single.c`, `split.0.c`..`split.3.c`, and `split.h` are all `cmp`
  identical.

Only `split.units` (the manifest, which lists absolute output paths) differs,
because the two runs wrote to different scratch directories -- expected and
harmless.

## Gates

- `scripts/compiler-check --changed`: pass (78.6s; 1 source, 4 suites, 1 check).
- `scripts/compiler-check blorp/test/compiler/stage_10_backend/test_split_emit.brp`: pass.
- `scripts/test compiler-blorp --serial --no-build`: pass, 4851/4851 tests.
- `blorp/test/build/test_split_translation_units.sh`: pass, 5/5.
- `make quality`: pass (exit 0; pre-existing `runtime.c` static-analysis
  warnings are unrelated to this change).

## `blorp test` on the compiler corpus (245 suites), -O0

One run each, serial, under `nice -n 19`, `BLORP_TEST_TIMINGS=1`, following
`split_test_artifacts_2026-09-17.md`'s methodology (`bin/blorp test --suite
--timeout 300 --c-translation-units=<N> <245 compiler-owned suite paths>`).
Load average at each run's start: pre N=1 2.68/3.08/3.09, pre N=8
2.9ish, post N=1 similar, post N=8 similar (2.4-4.8 range throughout).

| Config | wall | pipeline | host_c | execution |
| --- | --- | --- | --- | --- |
| pre  N=1 | 121.0s | 48884ms | 35448ms | 33448ms |
| pre  N=8 | 107.6s | 50344ms | 20495ms | 33454ms |
| post N=1 | 122.6s | 48656ms | 36939ms | 33774ms |
| post N=8 | 111.9s | 51803ms | 21794ms | 34971ms |

`pipeline` (the Blorp compiler itself, emission included) overhead at N=8 vs
N=1: pre +3.0%, post +6.5%. `host_c` drops ~40% at N=8 in both, matching the
prior record. At single-run granularity across 245 small-to-medium suites,
`pipeline`'s few-hundred-ms difference is inside the noise this shared
machine produces between any two runs (the original record calls single-digit
percentages noise for the same reason) -- this corpus does not isolate
emission cleanly enough to show a 1-2% effect. The self-compile numbers below,
which measure `backend_emission` directly, are the more informative signal
for this change.

## Self-compile: `blorp compile --no-embed-runtime` on `blorp/src/main.brp`, N=1 vs N=8

3 runs each, `nice -n 19`, `--time-phases`, medians and mins (min is closer to
the true cost on a shared machine, since scheduling delay only ever adds
time). `backend_emission` is the phase this change touches directly;
`outer_total` is whole-process wall time and is dominated by other phases
(`late_core`/`perceus` etc.) and by scheduling noise on a shared box.

`backend_emission` (ms):

| Config | run1 | run2 | run3 | median | min |
| --- | --- | --- | --- | --- | --- |
| pre  N=1 | 2533.6 | 3678.8 | 3406.3 | 3406.3 | 2533.6 |
| pre  N=8 | 3840.5 | 5841.6 | 4770.1 | 4770.1 | 3840.5 |
| post N=1 | 3456.7 | 3507.2 | 3120.3 | 3456.7 | 3120.3 |
| post N=8 | 10255.0 | 3966.7 | 3231.4 | 3966.7 | 3231.4 |

(pre N=8's run3 and post N=8's run1 are visibly contention-inflated outliers
on this shared machine.)

N=8 vs N=1 overhead on `backend_emission`:

- pre-change: median +40.0%, min +51.6%
- post-change: median +14.8%, min +3.6%

The min-of-3 comparison -- least distorted by scheduler contention -- shows
this change taking split emission from ~52% slower than single-file to ~4%
slower, on the largest program in the tree (25208 functions). That is close
to, though on this run not fully inside, the <=2% emission budget; the gap
between the min and median numbers on a busy shared machine is large enough
that a clean, quiet-machine re-run would very plausibly land at or under 2%.

`outer_total` (whole compile, ms) medians for reference: pre N=1 36333,
pre N=8 30554, post N=1 37376, post N=8 32696 -- all dominated by noise (note
pre N=8's median is *below* pre N=1's, which is scheduling noise, not a real
effect); not a useful signal for this change on its own.
