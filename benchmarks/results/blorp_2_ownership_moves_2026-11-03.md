# Blorp 2 moves at last use (2026-11-03)

`own` moves an owner whose obligation ends at a store, a yield, a selection
edge or a loop exit, instead of acquiring a new owner and dropping the old
one. One rule, `transfer` in `own/own.brp`, decides every owned slot.
`verify` loses its fresh-acquisition rule for loop edges, which now use the
yield rule. Keith approved this on 2026-11-03 from the spike
(`claude/pilot-moves-37493b`, `f8bc24db1` and `c94ba339b`, on `73102b901`).
The design is in [the ROADMAP](../../blorp/ROADMAP.md#moves-at-last-use).

## Provenance

| | Main | Branch |
| --- | --- | --- |
| Source | `20479ee36` (`blorp_2/src` as at `5e6511ab5`) | `blorp2/ownership-moves` |
| B C (sha256) | `fed4bf49dd85e95f42ebca395719e0384ccc9684732cdb5594c87ebc05bad4e1` | `5880c4ee587d9aead07ea5b97c62912e86a026387cd3420d893bd7c063d3797d` |
| B's C for main's source (sha256) | `f1c5152cc0b09c451dcf91edf5b765e043d0520cebb1f8eba53d54578eadd127` | `b7c7fd3e70b32fba2a82811c80c0de4c794fb243913e936c3f691673ecf86b7a` |
| Bytes of that C | 25,272,386 | 22,936,585 (−9.2%) |

- Both Bs come from the pinned seed (`blorp2-seed-0d11bd3de938`).
- Machine: Apple M4, Apple clang 21.0.0, load average 4 to 5 from other sessions.
- Every run was serial.
- Raw samples are in the ignored `build/ownership_moves/` of the branch worktree.
- After the review fixes, the branch B again wrote byte-identical C for main's source, so the measurements still hold.

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| Fixed workload: output C | identical | identical (`f1c5152c…`, which is also main B's own C) |
| Fixed workload: atomic RC operations | −25% or better | 436,705,358 → 312,397,536 (−28.5%) |
| Fixed workload: retired instructions, -O2, best of 5 | −5.5% or better | 14,867,085,986 → 13,847,187,618 (−6.9%) |
| Fixed workload: allocations | unchanged | 15,106,034 → 15,106,034 |
| Pass cost: B on main's source, instructions, -O0, best of 5 | at most +0.5% | 43,173,681,459 → 42,239,644,953 (−2.2%) |
| Pass cost: B on main's source, allocations | at most +0.5% | 15,106,034 → 14,891,442 (−1.4%) |
| Production lines, net | at most +100 | +16 (+277 / −261) |

**Fixed workload.** Each B compiles main's compiler source, and both
resulting programs then compile main's source. Both do the same work and
write the same C, so the comparison isolates `own`'s placement. Cycles, best
of 5, went from 3,745M to 3,342M (−10.8%); cycle counts are noisy.

**Pass cost.** The branch B is cheaper even though its `own` does more work,
because B is itself built with moves.

**Line counts.**
- Production: own +219 / −177, verify +56 / −83, emit +2 / −1.
- Tests: +486 / −96.

## Commands

```bash
R=build/ownership_moves; T=$R/main_tree/blorp_2; LIB=$T/standard_library; SRC=$T/src/main.brp
git archive origin/main blorp_2/src blorp_2/standard_library | tar -x -C $R/main_tree
scripts/blorp2-compiler-bootstrap --library-root $LIB $SRC $R/mainB.c   # main's B
cp blorp_2/build/compiler.c $R/branchB.c                                 # branch B (make -C blorp_2 compiler)
clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 -w $R/mainB.c -o $R/mainB -lm -lpthread    # likewise branchB, *Bdiag with =1
$R/mainB --library-root $LIB $SRC $R/C_main.c       # pass cost under /usr/bin/time -l, 5 alternating runs
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 -w $R/C_main.c -o $R/P_main -lm -lpthread  # likewise P_branch, Pd_* with =1
$R/P_main --library-root $LIB $SRC $R/out_main.c    # fixed workload, 5 alternating runs; cmp out_main.c out_branch.c
python3 -I blorp_2/scripts/attribution/instrument_rc.py --kinds $R/C_main.c $R/K_main.c
BLORP_RC_OUT=$R/rc_main.tsv $R/K_main --library-root $LIB $SRC $R/outk_main.c      # atomic RC operations
BLORP_LEAK_CHECK=strict $R/Pd_main --library-root $LIB $SRC $R/outd_main.c        # allocations
```

## Gates

- `make -C blorp_2 test`: exit 0, 988 PASS lines and 0 FAIL, which includes
  the strict-accounting self-compile.
- `scripts/blorp2-fixpoint --prove`, run alone: exit 0. B and C emit the same
  C, and `fixtures_identical_under_a_and_b=669`.
- Both gates were rerun by the test-runner on the final tree: 989 PASS and 0 FAIL;
  the fixpoint again found 669/669 fixtures identical.

## Tests

**Insertion** (`test_own/test_ownership_transfer.brp`):
- a dying owner moves into a record field;
- a repeated payload moves once and acquires once;
- a store before a later read acquires;
- a back edge moves a body owner;
- a yield moves arm owners into carriers;
- a value yielded twice moves once and acquires once.

**Verification** (`test_verify/test_ownership_transfer.brp`):
- accepted: a back edge moves a body owner, and also a header owner;
- rejected:
  - moving a pre-loop owner;
  - an inner loop moving an outer loop's owner;
  - moving a dropped owner;
  - a moved store that is also dropped;
  - a `break` that moves an enclosing owner it already dropped.

Each rejection checks the exact message and span.

**Oracles proven by breaking the code.**
- Making `transfer` ignore earlier moves fails both "moves once and acquires once" tests.
- Letting `loop_floor` accept any enclosing owner fails both floor rejections.

**Deferred suites.** `test_owned_prefix`, `test_source_loop_control`,
`test_tail_recursion` and `test_verify.brp` do not parse, so they are not run.
- Their three tests of the deleted "loop transfer must use a fresh acquisition" rule are deleted.
- Their five expectations of "loop transfer refers to a discharged owner" now name `consume_yield`'s message, "yield refers to discharged owner N".

## What remains

Of the spike's remaining move pool, about 6.3M pairs drop a loop-header owner
at an edge. A smaller share, about 0.65M, comes from owners entering a join that
a yield acquires and then retires. Moving those would need `consume_yield` to
let a yield discharge an entering owner.
