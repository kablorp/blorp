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
