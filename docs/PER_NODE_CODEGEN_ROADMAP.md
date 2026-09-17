# Per-Node Codegen Roadmap

The self-compile spends about 5,000 retired instructions per Core node per
pass. A hand-written C compiler pass spends 50 to 200. The gap is not in
what the passes compute; it is in what the generated C does around every
node: reference counting, cancellation cleanup frames, out-of-line runtime
calls, and repeated uniqueness tests. This roadmap attacks that per-node
cost. Every task here changes the generated C on purpose, so the oracle is
behavioral (suites, leak and sanitizer gates, cancellation fixtures) plus a
measured instruction reduction, never byte identity.

Read `COMPILER_SPEED_ROADMAP.md` first for the working agreement ("How To
Work A Task", "Reading profiles", "Quality bar"). This document adds what is
specific to codegen work: the stage-2 measurement rule, the attribution that
sizes each task, and the task specifications.

## Where we are

Measured on the frozen input (`0c2e104331a2`) with the harness at -O2:

| milestone | instructions | allocations |
| --- | ---: | ---: |
| start of the speed work (2026-09-15) | 333.2G | 329.9M |
| r4 baselines after round two | 231.0G | 241.0M |
| after the mono and Perceus builders (2026-09-17, main `fbd2cde37`) | ~223G | ~215M |
| after the first codegen round (2026-09-17, main `ddb934389`; r5 baselines) | 184.5G | 214.4M |
| the same compiler built by itself (stage-2, s2 baselines) | 176.6G | 214.4M |

A sampling profile of the Perceus pass (16.9% of the compile) attributed its
time as follows. The same categories apply to every walk in the compiler;
Perceus is only where it was measured.

| category | share of the pass |
| --- | ---: |
| the pass's own generated code | 32% |
| reference counting (`blorp_retain`, `blorp_release`, slow finish, destructors) | 29% |
| cancellation cleanup frames and slots, including their thread-local reads | 12% |
| allocation and free (`blorp_alloc`, libc malloc) | 12% |
| list operations (get, append, copy, ensure capacity) | 6% |
| String-keyed dictionary lookups and string compares | 3% |

Two consequences drive the task order. Allocation counts and instructions
have decoupled: the Perceus builder removed 31% of that pass's allocations
and 1.2% of the compile's instructions. And no single pass function
dominates; the cost is the runtime work every node does. So the levers are
the emitted patterns, not the passes.

## The per-node patterns, with the C they produce

Compile any small program with `bin/blorp compile --std-dir standard_library/src --no-format --no-embed-runtime -o out.c prog.brp`
and read `out.c`. This program shows every pattern in the task list:

```blorp
record Node { name: String, children: List[Node], depth: Int }

union Shape:
	Leaf(String)
	Branch(List[Shape], Int)
	Empty

pure func count_leaves(shape: Shape) -> Int:
	match shape:
		Leaf(name): 1
		Branch(items, _):
			var total: Int = 0
			for item in items:
				total += count_leaves(item)
			total
		Empty: 0

pure func rename(shape: Shape, prefix: String) -> Shape:
	match shape:
		Leaf(name): Leaf(prefix + name)
		Branch(items, depth):
			var renamed: List[Shape] = []
			for item in items:
				renamed = renamed.append(rename(item, prefix))
			Branch(renamed, depth)
		Empty: shape

pure func deepen(node: Node) -> Node:
	{ node | depth = node.depth + 1 }
```

**Pattern A: iterating a borrowed list.** `items` is a field of the borrowed
scrutinee and nothing in the loop can free it, yet the loop takes ownership:

```c
blorp_retain(items);
blorp_task_cleanup_duplicate_slot(&items);
__iterable_2 = items;
blorp_List* __iter_3 = __iterable_2;
blorp_CancelCleanupFrame __blorp_owned_cleanup___iter_3;
BLORP_TASK_CLEANUP_SCOPE(__blorp_owned_cleanup___iter_3);
blorp_task_cleanup_push(&__blorp_owned_cleanup___iter_3, &__iter_3, (void*)__iter_3, blorp_cleanup_release_arc_value);
long __len_3 = __iter_3->len; for (long __i_3 = 0; __i_3 < __len_3; __i_3++) {
  Shape* item = ((Shape*)blorp_list_get(__iter_3, __i_3));
  { blorp_cooperative_checkpoint(); }
  total = (total + brp_25(item));
}
blorp_task_cleanup_pop_slot(&__iter_3);
blorp_release(__iter_3);
```

That is one retain, one duplicate-slot call, one frame push, one pop, one
release, an out-of-line `blorp_list_get` per element, and an out-of-line
checkpoint per iteration, for a loop whose body is one addition and one call.

**Pattern B: last-use move pays a retain and a release.** `renamed` is
consumed by the constructor, but it is duplicated for the use and dropped at
scope end:

```c
blorp_retain(renamed);
Shape* __union_result_10 = __def_127_Branch((void*)renamed, (void*)(long)(depth), 1UL);
...
blorp_release(renamed);
```

The same shape appears when appending a fresh element (`blorp_list_retain_for`
on the element, then `blorp_release(__std_inline_elem)`), and when returning
a borrowed parameter (`blorp_retain(shape); blorp_task_cleanup_duplicate_slot(&shape);`).

**Pattern C: record update from a source that can never be unique.** `node` is
a borrowed parameter; the update retains it first, so the refcount is at least
two and every uniqueness test below is dead, yet three run:

```c
Node* __record_update_648 = ({ blorp_retain(node); node; });
blorp_String* __aggregate_field_0 = __record_update_648->name;
if (blorp_is_unique(__record_update_648)) { __record_update_648->name = NULL; } else { blorp_retain(__aggregate_field_0); }
blorp_List* __aggregate_field_1 = __record_update_648->children;
if (blorp_is_unique(__record_update_648)) { __record_update_648->children = NULL; } else { blorp_retain(__aggregate_field_1); }
Node* result = __blorp_reuse_record_Node(__record_update_648, __aggregate_field_0, __aggregate_field_1, node->depth + 1);
```

`__blorp_reuse_record_Node` tests uniqueness a third time. The earlier R2
probe measured this shape at +13.7% instructions on the DCE pass.

**Pattern D: the cleanup fast path reads a thread-local per operation.** In
`blorp/src/lib/runtime/native/runtime_decl.c` (around line 1064):

```c
static inline void blorp_task_cleanup_push(blorp_CancelCleanupFrame* frame, const void* slot, void* value, blorp_CancelCleanupFn release_value) {
    if (__builtin_expect(__blorp_current_task != NULL, 0)) {
        __blorp_task_cleanup_push_slow(frame, slot, value, release_value);
    }
}
```

`__blorp_current_task` is `_Thread_local` (runtime.c, near line 21124). On
macOS each read is a call through `_tlv_get_addr` unless the C compiler can
hoist it, and it usually cannot across the calls in between. A generated
function runs on one fiber, and the task pointer is set when a fiber resumes
(runtime.c near lines 22162 to 22196), so it is constant for the whole
execution of the function. Reading it once at function entry is sound.

**Why the frames exist at all.** A cancellation observed at a cooperative
checkpoint may leave the current C frame through `longjmp` (see
`blorp_cooperative_checkpoint` in runtime.c, near line 25682, and
`docs/CONCURRENCY_AND_RESOURCES.md`). Every loop calls the checkpoint, so any
owned value live across a loop, or across a call to a function that contains
one, needs a frame that the runtime can run when the fiber is abandoned. A
frame can be elided only when no checkpoint can be reached in the interval
it protects.

## Pattern counts in the compiler's own C

Counts in the generated C of `blorp/src/main.brp` at main `fbd2cde37`
(97 MB, 1.42M lines, 15,141 functions). Use the same greps as a cheap oracle
for whether a change did what it claims:

| pattern | count |
| --- | ---: |
| `blorp_retain(` | 54,022 |
| `blorp_release(` | 72,814 |
| `blorp_task_cleanup_duplicate_slot(` | 44,782 |
| `blorp_task_cleanup_push(` / `_pop_slot(` | 29,852 / 67,597 |
| functions with at least one cleanup frame | 7,385 |
| `blorp_list_get(` (out-of-line element read) | 13,473 |
| `blorp_cooperative_checkpoint()` | 4,596 |
| `blorp_is_unique(` | 7,639 |
| `__record_update_` temporaries | 15,438 |
| `blorp_list_retain_for(` (append with a retained element) | 3,686 |

Fieldless union variants, including `None`, are already immortal static
singletons (`__instance___def_NNN_None` with `BLORP_IMMORTAL_REFCOUNT`), so
"unbox payload-free variants" is done and is not a task here.

## The stage-2 rule (read this before measuring anything)

`bin/blorp` is compiled by the pinned bootstrap release
(`blorp/build/bootstrap.env`), not by the compiler in your worktree. A change
to the backend or to `runtime_decl.c` therefore does not change the code that
`bin/blorp` itself runs. The harness on `bin/blorp` would show only the cost
of pushing your new source through the old codegen, which is the wrong
number for every task in this document.

Measure a stage-2 compiler: the compiler compiled by your `bin/blorp`.

```bash
make && scripts/compiler-build-status          # stage 1: bootstrap compiles your source
benchmarks/build_stage2_compiler bin/blorp-stage2   # task N0 provides this; until it lands, use the recipe below
```

Recipe until N0 lands (mirrors the Makefile's `generate-blorp-cli-c` and
"Compiling Blorp CLI" steps; keep `-O2` and the runtime object the Makefile
already built):

```bash
export BLORP_CLI_C_OPTIMIZATION=-O2
make && scripts/compiler-build-status
bin/blorp compile --std-dir standard_library/src --no-format --no-embed-runtime \
  -o blorp/build/_build/blorp-cli/stage2_main.c blorp/src/main.brp
cc -O2 -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
  -include blorp/src/lib/runtime/native/runtime_decl.c \
  -Iblorp/src/compiler/stage_01_generated_inputs -Iblorp/src/compiler/stage_04_modules \
  -Iblorp/src/compiler/stage_06_typecheck/graph -Iblorp/src/compiler/stage_06_typecheck/type_system \
  -Iblorp/src -Iblorp/src/lib -Iblorp/src/lsp/server -Iblorp/src/test \
  blorp/build/_build/blorp-cli/stage2_main.c blorp/build/_build/blorp-cli/runtime-*.o \
  blorp/build/_build/blorp-cli/runtime_sources.c blorp/src/lsp/server/native_runtime.c \
  -lm -lpthread -o bin/blorp-stage2
```

Then measure with `--compiler bin/blorp-stage2 --skip-build-check`. The
baseline is a stage-2 compiler built the same way from your base commit
(build it once, keep it as `bin/blorp-stage2-base`), not the r4 JSON files,
which describe a bootstrap-built compiler. Compare stage-2 base to stage-2
candidate on both programs, three samples each at -O2.

Two more consequences. First, a stage-2 binary is built with the new
backend but its own runtime object comes from your worktree, so runtime
tasks are measured the same way. Second, the compiler's generated C size
(`output_bytes` in the harness JSON, and `wc -c` on `stage2_main.c`) is a
tracked metric for this roadmap: report it in every task.

## Sampling recipe

For attribution, sample the stage-2 binary compiling the frozen input:

```bash
input=$(benchmarks/self_compile_measure freeze --rev 0c2e104331a224226088519bb0509c00b9ac0b70)
bin/blorp-stage2 compile --no-format --no-embed-runtime --std-dir $input/standard_library/src -o /tmp/x.c $input/blorp/src/main.brp &
sample $! 60 1 -file /tmp/sample.txt
```

Generated functions are named `brp_NNN`; to map names, generate the C once
more with `--profile-mode calls` and read the metadata table it embeds
(`{"blorp_..._function_name", "brp_NNN", ...}`). Symbol ids are only stable
between two generations with the same flags, so generate the map and the
sampled binary from the same source and flags. Read the runtime symbols
(`blorp_retain`, `_tlv_get_addr`, `blorp_alloc`, ...) directly; they are the
categories that matter here.

## Working agreement for this roadmap

- One task per worker, in its own worktree and branch cut from `origin/main`
  (`git worktree add -b perf/<slug> ../blorp-rm-<slug> origin/main`). Never
  operate in another worktree. Commit per cut; do not rebase, merge, or push;
  the coordinator merges. Commit titles must stand alone (what changed, no
  task ids, no pasted tables).
- Sonnet with high reasoning for every task. Stop and end the turn with
  `QUESTION FOR COORDINATOR:` when a cut needs a contract change visible to
  user programs, when a fixture disagrees with your reading of a contract, or
  after three hours without a measured result. Never end a turn waiting on a
  gate; poll its log in a foreground loop.
- Fast loop: compile the sample program above and one of your own, read the
  C, grep the pattern counts. Medium loop: the small program through the
  harness. Slow loop: the stage-2 self-compile, three samples. Wall time is
  noise on this machine; instructions retired and the pattern counts are the
  signal.
- Gates per cut, one at a time, never in parallel background shells (macOS
  `syspolicyd` stalls under many fresh binaries): the owning suites, then
  `benchmarks/self_compile_measure lock -- scripts/test compiler-core-sanitize leak`,
  then `benchmarks/self_compile_measure lock -- scripts/compiler-check --changed --base main`.
  Measurements take no lock; run them before waiting on any gate. The full
  default `scripts/test` runs once per merge for this roadmap (the
  coordinator runs it), because every task changes every function's C.
- Do not change the order or placement of `DupExpr`/`DropExpr` unless the
  task says so, and never parallelize Perceus or the late Core passes.
- Prior art to read before starting: the task's "Where to look" list, the
  matching section of `COMPILER_SPEED_ROADMAP.md`, `docs/OWNERSHIP_MODEL.md`
  (the ownership ABI the C must respect), `docs/MEMORY_MODEL.md`, and
  `docs/CONCURRENCY_AND_RESOURCES.md` for anything touching cleanup or
  checkpoints. The backend's structure is in `docs/ARCHITECTURE.md`.

## Task order

Low-hanging fruit first, grouped so that tasks in the same tier touch
disjoint files and can run in parallel.

| tier | task | files | expected instructions | parallel with |
| --- | --- | --- | ---: | --- |
| 0 | N0 stage-2 build script and harness support | `benchmarks/` | none (enables the rest) | everything |
| 1 | N1 task pointer once per function | backend prologue, `runtime_decl.c` | -2 to -4% | N2, N3, N4, N5 |
| 1 | N2 inline element reads in `for` loops | backend loop renderer | -1 to -3% | N1, N3, N4, N5 |
| 1 | N3 one uniqueness test per record update | backend record update renderer | -1 to -3% | N1, N2, N4, N5 |
| 1 | N4 allocator pool coverage | `runtime.c` | -1 to -3% | N1, N2, N3, N5 |
| 1 | N5 inline cooperative checkpoint | `runtime_decl.c`, `runtime.c` | -0.5 to -1% | N1, N2, N3, N4 |
| 2 | N6 last-use move instead of dup and drop | `perceus.brp` | -5 to -10% | N8 |
| 2 | N7 borrowed iteration | `perceus.brp`, loop renderer | -2 to -4% | after N6 |
| 2 | N8 cleanup pops on exit paths, frame elision | `cancellation_plan.brp`, backend | -1 to -3% | N6 |
| 3 | N9 non-atomic refcounts while single-threaded | `runtime_decl.c` | -3 to -8% | measure first |

The percentages are ceilings inferred from the attribution and the pattern
counts, not promises; each task reports what it measured, and a task that
measures flat is dropped, not merged.

---

## N0. Stage-2 build script and harness support

**Context.** Every task below needs a stage-2 compiler and a stage-2
baseline. Today that is the hand recipe above.

**Change.** Add `benchmarks/build_stage2_compiler <output-binary>` (Python or
bash, matching the harness's style) that: checks `scripts/compiler-build-status`
is FRESH, runs `bin/blorp compile` on `blorp/src/main.brp` with the Makefile's
flags, links with the same command as the Makefile's "Compiling Blorp CLI"
step (read the variables from the Makefile rather than copying them, so an
`-I` change does not desynchronize), and prints the generated C byte count
and its sha256. Add a `--stage2` convenience to `benchmarks/self_compile_measure`
that builds into `bin/blorp-stage2` and measures it (equivalent to
`--compiler bin/blorp-stage2 --skip-build-check`), and make the comparison
output print `output_bytes` next to the instruction row. Document both in
`benchmarks/README.md` under the measurement protocol, with the stage-2 rule
stated in two sentences. Record the first stage-2 baselines from main:
`benchmarks/results/self_compile_stage2_baseline_O2_<date>_s1.json` and the
small-program equivalent.

**Feedback loop.** `benchmarks/build_stage2_compiler bin/blorp-stage2 && bin/blorp-stage2 --version`,
then the harness on the small program.

**Pitfalls.** The Makefile hashes inputs to skip work; the script must not
touch the Makefile's hash files or `bin/blorp`. The runtime object name
carries a config hash (`runtime-<hash>.o`); glob it or read the Makefile
variable. `--skip-build-check` bypasses the freshness check on the measured
binary, so the script must check freshness of `bin/blorp` itself before
building.

**Acceptance.** The stage-2 binary built from main compiles the frozen input
to the same C sha256 as `bin/blorp` does (the backend is unchanged at main,
so stage 1 and stage 2 must agree); the harness prints `output_bytes`; the
README paragraph exists; baselines recorded.

## N1. Read the task pointer once per function

**Context.** Pattern D. Owned by the cleanup-frames worker already running
(branch `perf/cleanup-frames`) as its first cut; listed here for
completeness and so no one duplicates it.

**Change.** In the backend's function prologue, when the function contains
any cleanup operation, emit `void* const __blorp_task = __blorp_current_task;`
and use `_with_task` variants of push, pop, duplicate, and scope exit that
take the pointer instead of reading the thread-local. Add the variants in
`runtime_decl.c` next to the existing inline functions; keep the existing
ones for the runtime's own C.

**Where to look.** `blorp/src/compiler/stage_10_backend/emit.brp` around
lines 2618, 2874, 12633, 12750, 12781, 13079 (frame declaration,
`BLORP_TASK_CLEANUP_SCOPE`, pops, duplicate); `prepared_backend_renderer.brp`
lines 852 to 960 and 1403; `runtime_decl.c` around line 1064.

**Acceptance.** Zero semantic change: cancellation and concurrency fixtures
green, leak and sanitizer gates green; `_tlv_get_addr` share in a stage-2
sample down; instructions down on both programs.

## N2. Inline element reads in `for` loops

**Context.** Pattern A's `blorp_list_get(__iter_3, __i_3)` is an out-of-line
call per element (13,473 sites). The loop already captured `__len_3`, and
`runtime_decl.c` has `blorp_list_get_inline` (around line 1190), which
branches on `storage_mode` and `elem_size`.

**Change.** In the loop renderer, hoist the storage decision out of the loop:
emit one branch on `__iter->storage_mode` before the loop (or, when the
element type is statically a pointer type, none at all) and read elements
with a direct indexed access to `__iter->data` inside the loop. Keep
`blorp_list_get` for the cases the renderer cannot classify. Do the same for
the index-based `List.get` when the receiver is the loop's own iterable and
the index is the loop counter, if that shape exists in the compiler's C
(grep for `blorp_list_get(__iter` first and report the count).

**Where to look.** The `for` loop arm in `emit.brp` (grep `__len_` and
`__iter_`), `prepared_list_renderer.brp`, and `blorp_list_get` /
`blorp_list_get_inline` / `blorp_list_store_raw` in `runtime.c` and
`runtime_decl.c` for the storage modes (`BLORP_LIST_STORAGE_INLINE` versus
`POINTER`) and the inline element size rules.

**Pitfalls.** Inline storage packs scalars at `elem_size`; a wrong stride is
silent memory corruption that only the sanitizer gate will catch, so run
`compiler-core-sanitize` after the first cut, not at the end. A loop body
that mutates the iterated list must still see the captured length semantics
the language defines (read `docs/MEMORY_MODEL.md` on iteration over a value
that is reassigned inside the loop; the current C iterates the original
allocation because `__iter_3` holds its own reference).

**Acceptance.** `blorp_list_get(` count in the compiler's C down by at least
80%; instructions down on both programs; suites for the backend and the
list runtime green; sanitizer and leak gates green.

## N3. One uniqueness test per record update

**Context.** Pattern C. Two shapes: a source that cannot be unique (a
borrowed parameter or any value the update retained first), where every
test is dead and the copy path should be emitted directly; and a source that
may be unique, where one test should select the whole path.

**Change.** In the record update renderer, classify the source once. When
the renderer knows the source was retained for the update (the
`({ blorp_retain(node); node; })` form) or is a borrowed binding, emit the
copy path: retain each carried field, construct fresh, release the source.
Otherwise emit `bool __unique = blorp_is_unique(src);` once and branch the
field moves and the reuse call on it (extend `__blorp_reuse_record_*` with a
variant that takes the flag, or emit the fresh path inline in the `else`).
Apply the same to the union reuse form at `emit.brp` ~24912.

**Where to look.** `emit.brp` ~10450 to 10560 (field carry with the
per-field uniqueness test), ~13089 to 13101, ~24481 (`__blorp_reuse_record_`
definition) and ~24912 (union reuse); `emit_record_layout.brp`;
`stage_09_core/reuse.brp` and `record_update_ownership` for what ownership
facts the Core already carries about the source (a `CowFieldTakeRetainPolicy`
exists; read the memory-model doc section on copy-on-write updates). The R2
probe report is summarized in `COMPILER_SPEED_ROADMAP.md` under round two.

**Pitfalls.** The field moves (`->name = NULL` on the unique path) exist so
the destructor of the reused object does not release fields that were moved
out; the single-test version must keep exactly that pairing. A release mask
on unions (`release_mask`) tracks which payload fields are owned; do not
change its meaning.

**Acceptance.** `blorp_is_unique(` count down by at least 40% in the
compiler's C; DCE pass instructions (the R2 probe's victim) down; identical
behavior on the record update and copy-on-write suites; leak gate green.

## N4. Allocator pool coverage

**Context.** `blorp_alloc` (runtime.c, grep `void* blorp_alloc(size_t size)`)
pops from a thread-local free list for four size classes (32, 64, 96, 128
bytes) and otherwise calls `malloc`. In the Perceus sample, `blorp_alloc`
plus libc allocation and free were 12% of the pass, and libc alone was
larger than `blorp_alloc`'s own time, which says many objects miss the pool
or the pool refills one object at a time.

**Change.** Measure first: add a temporary histogram of requested sizes
(and of pool hit versus miss) under `BLORP_COMPILER_MEMORY_PROFILE`, run the
self-compile, and report it. Then extend coverage where the histogram says:
more classes up to the size that covers 95% of requests, batch refills
(allocate a slab of N objects per miss instead of one `malloc`), and a
cheaper `blorp_pool_class` (a shift-and-table lookup rather than a loop, if
it is a loop). Keep the ASan exclusion (`BLORP_ASAN` disables the pool).

**Where to look.** `runtime.c` around lines 2203 to 2260 (`BLORP_POOL_*`,
`blorp_pool_free`, `blorp_pool_count`, `blorp_free`), `BLORP_POOL_MAX_DEPTH`
(the per-class cap, which decides how much memory the pool retains), and the
memory statistics block that `BLORP_COMPILER_MEMORY_PROFILE=1` prints (the
harness reads it, so keep its format).

**Pitfalls.** The pool is thread-local; objects freed on a different thread
than they were allocated on go to that thread's list, which is fine for
correctness but means slabs must not assume same-thread free. Peak RSS is a
tracked metric: a slab allocator that retains memory must not push peak RSS
up by more than a few percent (report it). The leak checker counts live
objects, not pool residency; verify the leak gate still reports zero.

**Acceptance.** Histogram reported; pool hit rate above 95% on the
self-compile; instructions down on both programs; peak RSS within +3%; leak
and sanitizer gates green; the runtime unit tests green.

## N5. Inline the cooperative checkpoint fast path

**Context.** `blorp_cooperative_checkpoint()` is an out-of-line call in every
loop iteration (4,596 sites). Its fast path is one thread-local decrement
and a branch (runtime.c near line 25682); the slow path resets the budget,
polls cancellation (which may `longjmp`), and yields.

**Change.** Split it: a `static inline` fast path in `runtime_decl.c` that
decrements a thread-local budget and calls the out-of-line slow path only
when it reaches zero. Then, in the loop renderer, read the budget's address
once per function (the same technique as N1: a thread-local read hoisted to
function entry) so the per-iteration cost is a decrement through a local
pointer and a branch.

**Where to look.** `runtime.c` `blorp_cooperative_checkpoint`,
`BLORP_COOPERATIVE_CHECKPOINT_INTERVAL`, the `BLORP_COOPERATIVE_CHECKPOINT_TEST_STAT_INC`
counters (tests read them; keep the counts identical on the slow path), and
the loop arm in `emit.brp`.

**Pitfalls.** The test stats count `checkpoint_calls` on every call; if the
fast path is inlined, that counter must still be maintained under the test
build flag or the scheduler instrumentation tests change. The budget must
stay per thread; hoisting its address per function is safe because a
function runs on one thread for its whole execution (a fiber migrates
between threads only while parked, and a parked fiber is not executing the
function body). Confirm that reading `docs/CONCURRENCY_AND_RESOURCES.md`
and the fiber resume code; if fibers can migrate mid-function, hoist only
the pointer read into the loop preheader instead.

**Acceptance.** Scheduler instrumentation and cancellation suites green;
instructions down on both programs; the checkpoint interval and cancellation
latency contract unchanged (the fixtures that measure them pass).

## N6. Move a local on its last use instead of dup and drop

**Context.** Pattern B, the largest lever: reference counting is 29% of the
sampled pass and a large share of it is the retain-then-release pair around
a value's final use as a constructor argument, record field, append element,
or return value. Perceus decides ownership; the backend only renders it.

**Change.** In the Perceus insertion walk, when a binding's last use is in
a consuming position (a call argument the contract consumes, a constructor or
record field, `List.append`'s element, a return), emit the use as a move and
no drop at scope end, instead of a dup at the use and a drop at scope end.
Start with immutable `let` bindings whose last use is syntactically last in
their scope and not inside a loop or a branch that is not the scope's tail;
measure; then extend to `var` bindings (which need the reassignment sites
considered) and to uses in the tail branch of a `match` or `if`.

**Where to look.** `stage_09_core/perceus.brp`: `insert_drops_expr_inner_result`
(the insertion walk), the `PerceusManagedLetPlan` record and
`managed_let_reuses_source`, `summarize_linear_ownership_uses` and
`OwnershipUseSummary` (`consumed_refs`, `required_refs`), the direct-consume
metadata in `PerceusInsertedExpr`, and `consumed_parameter_balancing_is_identity`.
`docs/OWNERSHIP_MODEL.md` defines consumed versus borrowed positions.
`test_core_perceus.brp` has the ownership-event fixtures
(`test_support_core_ownership_events.brp`); write the protecting test as an
ordered event signature first. The Perceus builder task's report
(`benchmarks/results/self_compile_perceus_accept_O2_2026-09-17.json` and
the round-three notes in `COMPILER_SPEED_ROADMAP.md`) has the attribution.

**Pitfalls.** A move is only sound when nothing after the use reads the
binding, including through a closure capture or a `defer`-like cleanup; the
cancellation frame for the binding must be popped at the move, not at scope
end. Do not change the order of drops that remain. The prepared-reuse pass
(`prepared_reuse`) and the reuse pass (`reuse.brp`) read Perceus's output;
run their suites.

**Acceptance.** `blorp_retain(` count in the compiler's C down by at least
15%; instructions down at least 3% on the stage-2 self-compile; leak and
sanitizer gates green; the full default `scripts/test` green at merge.

## N7. Borrowed iteration

**Context.** Pattern A. Iterating a borrowed collection needs none of the
retain, duplicate slot, frame, or release, when the loop cannot free it.

**Change.** In Perceus, classify a `for` iterable that is a borrowed
parameter, a field read from a borrowed binding, or an immutable local not
reassigned in the loop, as a borrow (`BorrowLetExpr` exists in the Core IR;
use it or its equivalent for the iterable). The backend then emits the loop
over the borrowed pointer without ownership operations. Keep the owned path
for iterables that are call results or are reassigned inside the loop.

**Where to look.** The `ForExpr` handling in `perceus.brp`
(`insert_drops_for_loop_expr`), `BorrowLetExpr` in `stage_09_core/ir.brp`
and how the backend renders it, and the loop arm in `emit.brp`.

**Pitfalls.** The loop body may reassign the variable the iterable came from
(`items = items.append(x)` inside `for item in items`); the current C
survives that because `__iter_3` holds its own reference. A borrowed loop
must fall back to the owned form whenever the iterable's source is
reassigned or consumed in the body. Cancellation at the checkpoint inside
the loop must not leave a borrowed value unreleased, which is automatic
(there is nothing to release) but the fixtures must still pass.

**Acceptance.** `blorp_task_cleanup_duplicate_slot(` count down by at least
30%; instructions down on both programs; leak and cancellation gates green.

## N8. Cleanup pops on exit paths and frame elision

**Context.** Owned by the running cleanup-frames worker as its second and
third cuts. Pops (67,597) outnumber pushes (29,852) because every exit path
re-emits the pops for the frames still open. And a frame whose protected
interval contains no reachable checkpoint is dead.

**Change.** Use one `__attribute__((cleanup))` scope where the exit paths
share the same set of open frames, without changing release order. Then
elide frames whose interval contains no loop, no call to a function that may
reach a checkpoint (a per-function "may cancel" fact computed once per
program from the pass list), and no other cancellation point.

**Where to look.** `cancellation_plan.brp` (the planner owns identity and
protocol; the renderer owns names), `builtin_is_cancellation_point` in
`stage_06_typecheck/type_system/builtins`, the emit sites listed under N1.

**Acceptance.** Push and pop counts down; cancellation fixtures green
including a new one per elided shape that cancels inside a function binding
managed values before and after the interval; leak gate green.

## N9. Non-atomic reference counts while single-threaded

**Context.** `blorp_retain` and `blorp_release` use atomic operations
(`BLORP_RC_DEC_PREV`); a `BLORP_SINGLE_THREADED` build flag exists. The
compiler runs its passes on one thread; only discovery and parsing use tasks.

**Change.** Measure first: build the stage-2 compiler with
`-DBLORP_SINGLE_THREADED` (if it links and the self-compile still runs
single-threaded) and report the instruction delta; that is the ceiling. If
it is above 3%, design a dynamic version: a process-wide flag set when the
first worker thread starts, tested with a predictable branch in the inline
fast paths, with the non-atomic path taken while it is clear. Any value
shared before the flag flips must be handled (the flag must flip before the
first thread can touch a managed object; read the scheduler startup).

**Where to look.** `runtime_decl.c` lines 1010 to 1060 (`blorp_retain`,
`blorp_release`, `BLORP_RC_*` macros), the scheduler startup in `runtime.c`
(grep `__blorp_current_worker_id`), and `docs/MEMORY_MODEL.md` on atomic
reference counts.

**Pitfalls.** This is the one task that can introduce a data race that no
suite catches; the sanitizer gate must include thread sanitizer on the
concurrency suites for it, and the coordinator decides after the ceiling
measurement whether the dynamic version is worth that risk.

**Acceptance.** Ceiling measured and reported before any design; if
implemented: instructions down at least 3%; all concurrency and runtime
suites green under the sanitizer gate; no change to any single-threaded
program's behavior.

---

## Acceptance and merge process for this roadmap

The coordinator merges. For each task:

1. Build stage-2 binaries for the base and the candidate, measure both on
   both programs (three samples, -O2); the candidate must reduce
   instructions on the self-compile by at least the task's floor and must
   not increase them on the small program by more than 0.5%. Report
   `output_bytes` and the task's pattern counts.
2. Gates: the owning suites, `compiler-check --changed --base main`,
   `compiler-core-sanitize leak`, and the full default `scripts/test`, all
   under `benchmarks/self_compile_measure lock --`.
3. Squash-merge the branch into one commit on main with a standalone title
   that describes the change; the measurement JSON under
   `benchmarks/results/` goes into that same commit. One task, one commit.
   Push to `origin main`.
4. Record a new stage-2 baseline pair (`_s<N>`) after each codegen merge,
   since the generated C legitimately changed. The bootstrap-built `r4`
   baselines stay valid for non-codegen tasks until the bootstrap is
   re-pinned; re-pin after the round so `bin/blorp` itself gets the wins.

---

## Results of the first round (2026-09-17)

Measured on main `ddb934389`, -O2, three samples, frozen input `0c2e104331a2`.
Bootstrap-built `bin/blorp` against the r4 baselines; stage-2 against s1.

| task | outcome | commit | instructions |
| --- | --- | --- | ---: |
| N0 stage-2 harness, sample attribution, s1 baselines | landed | `7ca248a81` | none |
| N5 inline cooperative checkpoint | landed | `077c1b82d` | -6.7% self, -2.2% small |
| N2 direct element reads in `for` loops | landed | `2bf941f73` | -2.1% stage-2 |
| N1 task pointer once per function | landed | `3b9e28440` | -0.65%, binary -2.2%, C +3.3% |
| N4 allocator pool: six classes, slab refills, one TLS lookup | landed | `f9f8ef8a2` | -14.4% vs r4; peak RSS +5.3% accepted |
| N8 frame elision with a runtime completeness guard | landed | `ddb934389` | frames -31%, C -3.8%, -0.44% |
| N3 one uniqueness test per record update | dropped, flat | branch `perf/record-update-uniqueness` | +0.08% |
| N6 last-use move | dropped, flat | branch `perf/last-use-move` | 0.0% |
| N9 non-atomic refcounts while single-threaded | deferred | none | ceiling -2.3% |
| N7 borrowed iteration | not started | | |

Combined: bootstrap-built 231.0G to 184.5G (-20.1%), stage-2 216.7G to
176.6G (-18.5%), stage-2 wall time to C 30.3s to 16.2s on the same
machine, allocations 241.0M to 214.4M, generated C for the compiler
130.0 MB to 129.2 MB. From the start of the speed work (333.2G) the stage-2
compiler is at 47% of the original instruction count.

What the round taught, for the next one:

- **The runtime's out-of-line calls dominated, not the emitted patterns.**
  The checkpoint (one call per loop iteration) and the allocator (a
  thread-local lookup per operation plus a depth cap that discarded
  reusable objects) were worth 21 points between them and changed no
  generated C. Look for the next such call before the next codegen task:
  candidates are `blorp_list_append`'s copy path, `blorp_string_concat`,
  and `blorp_release_slow_finish`'s destructor dispatch.
- **Uniqueness tests are cheap.** A relaxed atomic load and a compare;
  removing 2,000 static sites did not move a 216G count (N3).
- **Constructors are calls at Perceus time.** `RecordConstructExpr` and
  `UnionConstructExpr` do not exist before Perceus; a move into a
  constructor argument is a move into a `UserCall` argument, and the
  single-direct-consume machinery already handles that once its
  owned-result gate is understood (N6 found the gate has no safety reason
  but also that the shape almost never occurs).
- **The dup mass is escaping borrows.** Of 51,882 inserted dups on the
  self-compile, about 40,000 duplicate a `let` or match binding read once
  as a bare value or return, and only 482 to 678 of the let-bound ones have
  a matching drop in scope. The rest are required retains for borrowed
  values that escape (a match binding of a borrowed scrutinee returned to
  the caller). Reducing those needs an ownership design change (move
  fields out of a unique scrutinee, or return borrowed results), not a
  Perceus tweak. That is the next design question for reference counting,
  which remains the largest category.
- **Frames cost stack, not guards.** With the compiler running no tasks,
  every cleanup operation was a predicted branch; the real cost was the
  protected local pinned to memory. Elision (N8) is the lever; the
  remaining frames come from `BuiltinCall` names that do not map to one C
  symbol and from user functions containing loops.
- **The stage-2 rule is not optional.** The bootstrap-built compiler is
  3.5% slower than the same source compiled by itself; re-pin the
  bootstrap so `bin/blorp` gets the codegen wins.
