# Emitter join rewrites: append-in-place instead of `+` chains

Date: 2026-09-23

Branch `emit-joins`, squashed onto `origin/main`. Base for all comparisons:
merge-base `5cf87a20245ddd474dd90222c783a9a6df3d5bcf` (`origin/main` at the
time this work started). Candidate: the three commits described below,
combined into this one landed change.

## Hypothesis

`benchmarks/results/emitter_copy_factor_2026_09_23.md`'s copy-site
attribution (return-address histogram on `blorp_string_concat`/`_append`/
`_concat_many`) named four families of "small+big chained" and "big+big"
`+`-chain joins in `emit.brp` where a large operand (a whole statement
block or function body) gets re-copied on every subsequent `+` in the
chain, rather than copied once: `emit_constructor_match` +
`emit_constructor_match_branch_body` + `emit_literal_match_branch_body`
(~1.32 GB), `statement_expression` + `apply_let_cleanup_to_body` (~1.05 GB),
`emit_general_supported_user_function`/`emit_function`/`emit_function_body`
(~0.76 GB), and `with_current_task_local` (~95 MB, split-and-rejoin rather
than a chain). Hypothesis: binding the large operand(s) to a local `var`
first and appending the rest with `+=` (which the runtime's
`blorp_string_append` already does in place when the buffer is uniquely
owned) copies each large operand once instead of N times, for identical
output.

## Workload and exact commands

Per-family copied-byte measurement (bootstrap-built compilers, not
stage-2): a temporary counter was added to `blorp_string_concat`,
`blorp_string_concat_consume`, `blorp_string_append`, and
`blorp_string_concat_many` in
`blorp/src/lib/runtime/native/runtime.c`, gated on the existing
`__blorp_compiler_memory_profile_enabled` flag and printed at teardown as
`BLORP_COMPILER_MEMORY_STRING_BYTES` under `BLORP_COMPILER_MEMORY_PROFILE=1`.
Reverted before every commit; no runtime.c change is part of the landed
diff.

Workload: a frozen copy of `blorp/src` + `standard_library/src` at
`origin/main` (`git archive origin/main | tar -x -C <frozen>`, with
`embedded_std.brp`/`compiler_build_info.brp` copied in from a `make`
build since those are gitignored generated inputs), compiled by each
side's own `bin/blorp`:

```
BLORP_COMPILER_MEMORY_PROFILE=1 <bin/blorp base|candidate> compile \
  --std-dir <frozen>/standard_library/src --no-format --no-embed-runtime \
  -o <out>.c <frozen>/blorp/src/main.brp
cmp base.c candidate.c   # byte-identical, every family
```

`base`/`candidate` for each family are two `bin/blorp` builds from trees
that differ only in `blorp/src/compiler/stage_10_backend/emit.brp` (base =
the previous family's post-fix state or the merge-base for family 1;
candidate = with that family's rewrite applied), both built with `make`
against the same pinned bootstrap (`dev-6aca1d029bf0`).

Combined-delta measurement (allocations, instructions, peak RSS): the
repo's own harness, stage-2 compilers on both sides, frozen input at the
merge-base:

```
python3 benchmarks/self_compile_measure freeze --rev 5cf87a20
python3 benchmarks/self_compile_measure measure --stage2 \
  --input-rev 5cf87a20 --label base --output base.json --samples 3
# checkout candidate, rebuild bin/blorp, then:
python3 benchmarks/self_compile_measure measure --stage2 \
  --input-rev 5cf87a20 --label candidate --output candidate.json \
  --baseline base.json --require-identical --samples 3
```

Base provenance: `bin/blorp` built from `5cf87a20245d`, stage-2 compiler
`compiled_by: self-5cf87a20245d`. Candidate provenance: `bin/blorp` built
from the three-commit tip (`11e16948` at measurement time, before the
final squash/rebase onto the newer `origin/main`), stage-2 compiler
`compiled_by: self-11e169481d8f`. Both `optimization: cli=-O0
runtime=-O2`, same `cc_version` (Apple clang 21.0.0) — no toolchain
mismatch.

## Per-family copied bytes (bootstrap-built, frozen-workload)

| Family | Function(s) | Before | After | Delta |
| --- | --- | ---: | ---: | ---: |
| 1 | `emit_constructor_match` + branch/fallback siblings (6 sites) | 6.22 GB | 6.01 GB | -3.4% |
| 2 | `statement_expression`, `apply_let_cleanup_to_body` | 6.01 GB | 5.28 GB | -12.2% |
| 3 | `emit_general_supported_user_function` (6 branches) | 5.28 GB | 5.10 GB | -3.25% |
| **Combined** | | **6.22 GB** | **5.10 GB** | **-18.0%** |

Each family's `before`/`after` C output was byte-identical (`cmp`); each
commit individually passed `scripts/compiler-check --changed --base
origin/main` (354/354) and `scripts/test compiler-blorp` (5052/5052).

## Combined stage-2 measurement (all three commits vs. merge-base)

Generated C: **identical**, 141,879,831 bytes both sides
(`--require-identical` passed, exit 0).

| metric | base | candidate | delta |
| --- | ---: | ---: | ---: |
| total allocations | 230,847,946 | 230,543,747 | -0.13% |
| `backend_emission_complete` allocations | 19,566,255 | 19,262,056 | -1.55% |
| instructions retired (min of 3) | 356,921,020,983 | 356,503,748,985 | -0.12% |
| peak RSS (bytes) | 2,506,260,480 | 2,503,606,272 | -0.11% |

Every phase before `backend_emission_complete` is flat at +0.00%, as
expected — the change only touches the backend.

## Retracted figure: commit-1 peak RSS

While developing commit 1 in isolation, an ad-hoc, non-stage-2,
single-sample measurement (`--no-embed-runtime` CLI-only compile of
`blorp/src/main.brp`, bootstrap-built compiler, not the
`self_compile_measure` harness) reported peak RSS dropping from 2.33 GB to
1.82 GB (-22%) for that commit alone. This did **not** reproduce under the
proper stage-2/frozen-input harness: re-measuring commit 1 alone against
the same merge-base, twice, gave peak RSS deltas of +0.22% and -0.11% —
noise, not a real effect. **The -22% figure is retracted** and should not
be cited; the real peak-RSS effect of this work is the -0.11% combined
figure in the table above.

## `with_current_task_local`: left unrewritten

This family (~95 MB of the original 7.6 GB census) inserts the
`__blorp_task` local-variable declaration into an already-rendered
function body via `function_c.take_left(body_start) + indent + DECL +
function_c.drop_left(body_start)`. The final `+` chain is not the
problem — the large operand (`drop_left(...)`'s result) is last in the
chain and is already copied only once by the concat. The actual double
copy is `drop_left` itself: producing that slice requires allocating a
fresh string and copying the (almost the whole) function body's tail out
of `function_c`, which was itself already a complete, freshly-built
string. Avoiding that copy means inserting the declaration at the point
the function body is first assembled instead of after the fact — but that
assembly happens several call levels away, inside
`emit_general_supported_user_function` and `emit_closure_body_function`,
behind an opaque `String` return that `emit_function`'s caller of
`with_current_task_local` never sees uncombined. Reaching it would mean
threading additional information across those non-local call sites (or
widening the shared `FunctionBodyC`-adjacent return type), which the
task's rules explicitly rule out for a local-rewrite-only pass. Left
unchanged; no commit touches it.
