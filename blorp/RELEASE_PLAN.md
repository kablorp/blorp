# Release in constant C stack

Plan revision 1, 2026-11-16, written against origin/main `4d350add0` and
rebased onto `4d8b381f0` on 2026-11-17, where the measurements below were taken. The
deep-release pilot of 2026-11-12 found the problem and measured the options;
its probes, prototypes and raw samples are in the main checkout's ignored
`build/pilots/2026-11-12/deep-release/`.

**Status:** approved by Keith on 2026-11-16 (decisions below). Two landings,
stacked: L1, the cold split, and L2, the depth budget. No seed rotation is
part of this plan; the compiler's own code gains L1's speed once a later seed
carries it.

## Problem

Releasing a recursive value recursed through the generated drop helpers: a
record's drop called its fields' drops, an inline union's drop its payloads',
a List's drop its elements', a callable's drop its environment's. A value's
depth became C stack depth, so every recursive shape except a boxed union
crashed on the default 8 MB stack. Base failures, bisected to 1%:

| Shape | -O0 | -O2 |
|---|---:|---:|
| record, `Option[Node]`, record (`record Node { value: Int, next: Option[Node] }`) | 87,500 | 262,000 |
| the same as a tree: a left spine with right leaves | 87,500 | 262,000 |
| inline union, record with a String | 87,500 | 262,000 |
| record, `List[Node]`, record | 75,000 | 175,000 |
| `Many(List[Nest])` | 75,000 | 175,000 |
| callable, closure environment, callable | 75,000 | 262,000 |

A boxed union with one self payload already released in a loop, keeping its
one child; that loop is why a boxed variant may hold only one self payload.

## Keith's decisions, 2026-11-16

1. The release scheduler is approved as a mechanism: per-thread park stacks,
   the kinds enum and dispatch, `_Thread_local`, and a `__GNUC__`-guarded
   `noinline,cold` attribute in emitted C.
2. Every drop helper has two entry points, `drop` and `drop_at`. The static
   per-component alternative is not pursued.
3. The depth limit is 128 nested counted releases, a named constant.
4. The cold split lands first, as its own change.
5. Removing the one-self-payload rule belongs to the recursive-unions work,
   which is not decided yet.

## Landings

1. **L1, the cold split** (`emit`, List runtime). A counted layout's drop
   only decrements and calls a separate release body, which drops the
   children and frees the object: `blorp_record_release_N`,
   `blorp_list_release_S` and `blorp_union_release_N`. The C compiler then
   inlines the decrement where a value is dropped and calls the release out
   of line; a drop with the release inside was too large to inline. Behaviour
   is unchanged: the same objects are freed in the same order.
2. **L2, the depth budget.** Every drop helper gains a nested form,
   `drop_at(value, depth)`, where `depth` counts the counted releases running
   below it; `drop(value)` is `drop_at(value, 0)`. A layout whose release may
   release a child that owns children joins the scheduler: below
   `BLORP_RELEASE_DEPTH_LIMIT` its release runs directly at `depth + 1`; past
   it the dead object goes to `blorp_release_deep`, which parks it on a
   per-thread stack for its kind, linked through its own dead count word, and
   one out-of-line loop releases parked objects at depth 1. Release allocates
   nothing and C stack use stays within two limits of nested releases. The
   boxed union's one-child walk is deleted.

## Measurements

Host: Apple M4, macOS 26.7.1, Apple clang 21.0.0. Other sessions ran gates
throughout. Allocations come from one strict run of a
`-DBLORP_MEMORY_DIAGNOSTICS=1` binary and are deterministic; instructions and
cycles are medians of alternating `/usr/bin/time -l` runs.

`blorp/scripts/self-compile-cost` builds both sides from the pinned seed, so
it cannot see a change to emitted release code. These numbers come from
stage-2 compilers: each side's seed-built compiler compiles its own source at
`-O2`, normally and with memory diagnostics, and every stage-2 compiler then
compiles the base's source.

### L1 (2026-11-17)

Base `4d8b381f0`, candidate `release/cold-split` (gated at `e8ad02634`).
Medians of 7, alternating.

| | Base | L1 | Change |
|---|---:|---:|---:|
| Allocations (strict) | 14,315,638 | 14,318,708 | +3,070 (+0.021%) |
| Peak heap (bytes) | 171,306,620 | 171,307,662 | +1,042 |
| Instructions | 12,783,495,077 | 12,496,862,859 | −2.24% |
| Cycles | 3,151,435,722 | 3,057,041,146 | −3.00% |
| Peak RSS (bytes) | 252,313,600 | 251,117,568 | −0.47% |
| `__text` (bytes) | 3,489,576 | 3,645,924 | +4.48% |

- The allocations and peak heap that rise are the emitter's: L1 writes a
  release body beside every counted drop, 2.6% more C. The release itself
  changes nothing. On `4d350add0`, the base's source compiled by L1's
  seed-built compiler (L1's release code, the base's emitter) allocated
  exactly the base's 14,198,835 with the same 170,298,706-byte peak, emitted
  the same C for the base's source as the base stage-2 compiler
  (`8fd09726…`, which reproduces its own C), and measured −2.36%
  instructions and −2.35% cycles. Strict counts can differ by one between
  runs (14,198,834 and 14,198,835 for the same compiler).
- Mechanism, from the base's stage-2 C at `4d350add0` rewritten to the split
  and compiled at `-O2`: inline atomic decrements rise from 24,320 to 30,949,
  and 4,718 of the 7,409 calls to record drops become inline decrements with
  out-of-line release calls (6,271 record and 1,742 List release calls).
- `make -C blorp test INSTRUCTION_CHECK=on` passes at `e8ad02634` (3,045
  passed, none failed, no ceiling exceeded): every exact runtime allocation
  count, printed output and compile ceiling is unchanged. On `4d350add0`,
  `scripts/blorp-fixpoint --prove` passed with 749 of 749 fixtures emitting
  identical C under stages A and B.
- `test_emit/test_release.brp` fails with the base's emitter and passes with
  L1's (three cases: record, List and boxed union drops).
- Raw samples: the main checkout's
  `build/pilots/2026-11-12/deep-release/landing/l1-main/`, and `landing/l1/`
  for the runs on `4d350add0`.

### L2 (2026-11-17)

Base `release/cold-split`, candidate `release/depth-budget`.

- **Deep fixtures.** Seven e2e cases in `test_compile/data.brp`, one per
  shape in the Problem table and a boxed union, each a million levels deep.
  Built as the harness builds them (`-O0`, ASan and UBSan, strict
  accounting), the first six abort with a stack overflow under `4d8b381f0`'s
  compiler, and every one exits normally with a balanced report under L2's:

  | Fixture | Status | Runtime allocations |
  |---|---:|---:|
  | `recursive/deep_record_chain` | 49 | 1,000,000 |
  | `recursive/deep_record_tree` | 49 | 2,000,000 |
  | `recursive/deep_union_chain` | 4 | 1,000,001 |
  | `recursive/deep_list_chain` | 49 | 1,999,999 |
  | `recursive/deep_nested_list` | 1 | 1,000,000 |
  | `recursive/deep_boxed_chain` | 3 | 1,000,001 |
  | `recursive/deep_closure_chain` | 7 | 1,000,000 |

  The boxed chain passed at the base through the one-child walk L2 deletes;
  it guards that deletion. The compile ceilings are L2's test compiler's
  measured cost plus 15%. With `BLORP_RELEASE_DEPTH_LIMIT` raised to
  1,000,000,000, so that nothing parks, all seven abort with a stack
  overflow, so these cases catch a disabled budget.
- **Runtime suite.** `test_runtime/release_suite.brp` runs two C probes under
  the strict check.
  - The scheduler probe drives `RELEASE_RUNTIME` through two counted layouts
    written to the emitted protocol: a 128-node chain releases without
    parking; a 129-node chain parks once; a 1,000,000-node chain parks every
    128th node (7,812 dispatches) and no release runs deeper than 128; a
    spine of pairs mixes parked nodes and pairs in one run (1,007
    dispatches); a shared chain parks only when its last owner releases it.
    Every mode allocates nothing while releasing and leaves no run open.
  - The emitted-helpers probe takes the helpers `aggregate_runtime` emits
    for a fixed program, admitted by a typed catalogue check, builds a
    million records chained through `Option`, a million chained through
    Lists and a million boxed `Succ` nodes, and releases each on a thread
    with a 512 KB stack.

  With `BLORP_RELEASE_DEPTH_LIMIT` raised to 100,000,000 in the runtime
  text, all eight cases fail, and the three emitted-helper cases are killed
  by ASan's stack-overflow abort.
- **Existing tests.** L1's `test_emit/test_release.brp`, which compared
  helper text, is removed; the probes above check what the helpers do. The
  pinned text in `test_managed_union` (11 cases) and
  `test_static_environments` (1 case) and the callable ops in
  `list_reuse_test.c` follow the new helpers.
- **Stage-2 self-compile.** Base `4d8b381f0`, L1 and L2 measured together on
  the base's source; medians of 7, rotating order.

  | | Base | L1 | L2 | L2 against base |
  |---|---:|---:|---:|---:|
  | Allocations (strict) | 14,315,637 | 14,318,707 | 14,334,215 | +18,578 (+0.13%) |
  | Peak heap (bytes) | 171,306,620 | 171,307,662 | 172,379,170 | +1,072,550 (+0.63%) |
  | Instructions | 12,750,805,908 | 12,461,711,725 | 12,678,035,368 | −0.57% |
  | Cycles | 3,086,618,597 | 3,029,058,103 | 3,050,387,936 | −1.17% |
  | Peak RSS (bytes) | 252,248,064 | 251,576,320 | 251,625,472 | −0.25% |
  | `__text` (bytes) | 3,489,576 | 3,645,924 | 3,933,476 | +12.7% |
  | C for the base's source (bytes) | 27,130,738 | 27,202,419 | 27,701,332 | +2.10% |

  Against L1, L2 costs 1.74% of instructions and 0.70% of cycles: the depth
  argument every nested drop passes, and the larger code. The allocations and
  the peak heap rise with the emitted C (742 kinds, and a nested drop beside
  every drop); the peak heap is the output join. Release itself allocates
  nothing.
- **Final gates.** Both branches rebased onto `f95a8204d`; `make -C blorp
  test INSTRUCTION_CHECK=on` on each final commit. L1: 3,055 passed; the only
  failures are two compile instruction ceilings, 34,464,057 against
  34,081,067 and 34,876,490 against 34,660,030. L2: 3,068 passed, nothing
  failed and no ceiling was exceeded.
- **Ceilings.** Those two ceilings, `derived_accepted_generic_head` and
  `derived_accepted_nested_generic_head`, are stale on main itself: the same
  harness with `4d8b381f0`'s own test compiler exceeds them.

  | Case | Ceiling | Main in the harness | L2 in the harness (gates) |
  |---|---:|---:|---:|
  | `derived_accepted_generic_head` | 34,081,067 | 34,371,861 | 34,284,483 and 34,275,457 |
  | `derived_accepted_nested_generic_head` | 34,660,030 | 34,778,323 | 34,692,732 and 34,785,509 |

  Medians of 7 outside the harness agree that L2 does not raise them: main
  33,103,501 and 33,407,463, L2 33,100,936 and 33,545,172. The coordinator
  owns their correction. The two ceilings the pilot exceeded no longer bind:
  `files/write` compiles in 244,460 allocations at the base and 244,553 with
  L2, under its 247,760 ceiling (main had reset it from the pilot's 234,300),
  and `derived/accepted_generic_head` allocates within its 4,719 ceiling.
- **Size.** Production lines: L1 +40 −20, L2 +390 −130.
- Raw samples: the main checkout's
  `build/pilots/2026-11-12/deep-release/landing/l2/`.
