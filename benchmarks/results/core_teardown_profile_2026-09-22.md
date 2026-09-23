# Core teardown ceiling profile (2026-09-22)

Measured on `teardown` branch cut from `origin/main` (`71fa20899730`), -O2,
one sample, frozen input `0c2e104331a224226088519bb0509c00b9ac0b70`. Stage-2
`bin/blorp-stage2` built by bootstrap-built `bin/blorp` (`compiled_by:
dev-f3ee0efea3b2`, `optimization: cli=-O2 runtime=-O2`, `cc: Apple clang
21.0.0`), 60s `sample` at 1ms interval over the frozen-input self-compile,
12295 total main-thread samples, plus a separate
`BLORP_COMPILER_MEMORY_PROFILE=1` run of the same self-compile for
allocation/pool histograms and per-pass live-object counts. Not yet
committed; this is the step-1 measurement only, no code changed.

## Headline: destructor-frame share of the compile

Self-time (not inclusive — inclusive double-counts through recursive
teardown chains) in every destructor-related frame:

| symbol / group | self samples | share |
| --- | ---: | ---: |
| `blorp_release_slow_finish` (self) | 495 | 4.03% |
| `blorp_list_destroy` (self) | 334 | 2.72% |
| `blorp_elem_release_fn` (self) | 259 | 2.11% |
| `blorp_get_destructor_id` (self) | 120 | 0.98% |
| `blorp_release_slow_extern` (self) | 97 | 0.79% |
| `blorp_dict_destroy` (self) | 67 | 0.54% |
| `CoreExpr_destroy_fields` + `.cold.*` | 116 | 0.94% |
| `CoreExpr_destroy_release_child` | 55 | 0.45% |
| `CoreType_destroy_fields` + cold | 22 | 0.18% |
| other `*_destroy_fields` (Parsed/Typed/Dce/Perceus/lower/match frame stacks) | 34 | 0.28% |
| **total destructor-frame self samples** | **1609** | **13.09%** |
| libc free family (`_free`, `free`, `_xzm_free*`) reached only from teardown | 459 | 3.73% |
| **grand total (destructor dispatch/RC + libc free)** | **2068** | **16.82%** |

This lands close to the roadmap's own prior 11.5% figure (different build/
sample duration/session). `blorp_retain`/`blorp_release`/`blorp_is_unique`
show 0 self samples — they are `always_inline` fast paths with no standalone
symbol, consistent with the runtime source.

## (a) Which owner released it

This is the key finding: **the cost is not concentrated in the pass_runner's
bulk supersede-drop.** `run_core_passes` (`brp_439`) appears at 7 call-graph
locations, inclusive 9222/12295 samples (75%, expected — it's the whole
late-Core pipeline body). Its *direct* children that are themselves a release
call (i.e., the literal `current = advanced` drop of the just-superseded
`CoreProgram`, not a nested call into a pass's own rewrite closure) total
only **239 samples (1.9% of the compile)** — two `blorp_release_slow_finish`
leaf hits (122 + 117), with no further captured children, i.e. cheap.

That is far below the 13% destructor total above. The rest of the destructor
cost is inside individual passes' own node-by-node dup/drop machinery
(Perceus insertion, DCE's dead-node drops, match/backend projection
rewriting some nodes) and, per-pass memory checkpoints below, most passes do
not show a live-object spike-then-collapse pattern — `current_objects` stays
roughly flat or grows through the late-Core span (e.g. 12.4M → 15.8M across
`pass_match_projection_complete` → `pass_dce_complete`). That is consistent
with `reuse.brp`'s record-update reuse already mutating unique nodes in
place for many passes, so `current = advanced` is frequently a cheap
same-object (or mostly-shared) reassignment rather than "drop an entire
independent tree, then build a second independent tree."

Frontend `TypedProgram`/`TypedExpr`/`TypedDecl` release is negligible: 9
self samples (0.07%) across `TypedExpr_destroy_fields` and
`_destroy_release_child`; `TypedDecl_destroy_fields` had 0 self samples in
this run.

Within-pass temporaries (`DceExprStack_destroy_fields`,
`PerceusOwnershipSummaryFrameStack_destroy_fields`,
`ContractCollectionTaskStack_destroy_fields`,
`FlattenRewriteBindingFrameStack_destroy_fields`,
`PatternBindingSequence_destroy_fields`) sum to about 20 self samples
(0.16%) — also small on their own; most of the `CoreExpr`/`CoreType`
`_destroy_fields` and `blorp_list_destroy`/`blorp_dict_destroy` cost (450+
samples, 3.7%) is generic child-list/subtree teardown reached from many
different call sites (per-pass rewrites, not one bulk drop), which the
sampled call graph does not cleanly attribute to a single owner without
much deeper (and noisier) per-call-site bookkeeping than a single 60s sample
supports.

Number of superseded-`CoreProgram` releases per compile: **36** distinct
`pass_<name>_complete` memory checkpoints fired exactly once each for this
whole-program compile (19 late-Core passes from `late_core_passes()` plus
17 earlier Core passes: lower, debug, prune_early, desugar, mono, synth,
match, trait_resolve, prune_after_trait_resolve, resolve, std_inline,
tailrec, fuse_string, fuse_collection, fuse_parallel_tensor,
fuse_tensor_update, tuple_sroa) — i.e. 36 `current = advanced` drop sites,
each of the size measured above (cheap individually).

## (b) Leaf cost split

| leaf category | self samples | share |
| --- | ---: | ---: |
| dispatch (`blorp_get_destructor_id`, `blorp_elem_release_fn` indirection) | 379 | 3.08% |
| refcount decrement | 0 (inlined, no distinct symbol) | — |
| `blorp_release_slow_finish`/`_extern` own bookkeeping (pool-class branch, pool push, alloc_meta, stats) | 592 | 4.82% |
| libc free (oversized/non-pooled objects, ASan-off path) | 459 | 3.73% |
| list/dict element-loop teardown (`blorp_list_destroy`, `blorp_dict_destroy`) | 401 | 3.26% |
| type-specific `_destroy_fields`/`_destroy_release_child` switch/field-walk self | 237 | 1.93% |

Pool-push vs. non-push instructions inside `blorp_release_slow_finish`'s own
495 self samples cannot be split further without disassembly-level line
sampling; qualitatively the branch+push is a handful of instructions, so
most of that self time is the `__alloc_meta_take` check and stats
conditionals, not the pool push itself.

## Allocator histogram (`BLORP_COMPILER_MEMORY_PROFILE=1`, full self-compile)

```
total_allocations=193,285,752  total_releases=173,962,957  current_objects=19,322,795 (at artifact_construction_complete; process exit frees the rest)
pool_hit_32=28,900,915   pool_miss_empty_32=20,344
pool_hit_64=107,347,518  pool_miss_empty_64=141,930
pool_hit_96=38,295,424   pool_miss_empty_96=134,620
pool_hit_128=7,147,164   pool_miss_empty_128=4,469
pool_hit_192=4,543,945   pool_miss_empty_192=2,877
pool_hit_256=2,071,785   pool_miss_empty_256=2,666
pool_miss_oversized=4,672,105   (2.4% of all allocations, freed via libc, matches the 3.7% libc-free sample share above given oversized objects also cost more per free)
pool_pushed_{32,64,96,128,192,256} sum to 177,834,026; pool_discard_oversized=4,670,127
```

Pool hit rate across covered classes is >99.5% (N4, already landed on
main). The oversized/uncovered tail (~2.4% of allocations) is the main
remaining allocation-side cost and is a pre-existing, already-measured gap,
not new to this task.

## Step 2 recommendation

Per the task's own rule ("If either is under 3% of the compile, tell me
before doing it"):

- **Design B (off-critical-path reclaim of the superseded `CoreProgram`)**:
  ceiling ≈ **1.9%** (the direct pass_runner drop share) — clearly under 3%,
  and the mechanism it targets (one big bulk drop per pass) is not actually
  what's happening; most passes reuse nodes in place, so there is no single
  coarse "hand this whole tree to another thread" moment to exploit. **Out.**
- **Design A (direct destructor call instead of id-indexed dispatch for
  statically known field types)**: ceiling ≈ **3.1%**
  (`blorp_get_destructor_id` 1.0% + `blorp_elem_release_fn` indirection
  2.1%), right at the 3% floor, before accounting for any inherent
  indirect-call misprediction cost folded into `blorp_release_slow_finish`'s
  own 4.0% self time (not separable further without line-level profiling).
  Marginal, not a clear win.

Both ceilings are at or under the 3% floor. Stopping here per instructions
rather than implementing either — requesting go/no-go.
