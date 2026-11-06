# Blorp 2 borrowed field projections (2026-11-03)

`own` keeps a managed record field read as a borrow of its parent while the
parent's obligation outlives every read of the field. Before, it acquired the
field straight after the read and dropped it later. Where the parent's
obligation ends is asked of `transfer`'s own predicate, so the decision sees
every drop and move of [moves at last use](blorp_2_ownership_moves_2026-11-03.md).
`verify` and `emit` are unchanged. Keith approved this on 2026-11-03 from the
pilot (spike `25287b208` on `73102b901`). The rule is in
[the ROADMAP](../../blorp/ROADMAP.md#borrowed-field-projections).

## Provenance

| | Main | Branch |
| --- | --- | --- |
| Source | `d2bbd1f0e` | `blorp2/borrowed-projections` |
| B C (sha256) | `265dc0a7f359199da199dc1e71889d108eaa1e1d89e1b42c654b41e003fa161f` | `5bc5eac2aad20e7e76c8f787feec877fd55f8ab8e2643d10b9bd8b6d32a01937` |
| B's C for main's source (sha256) | `cde87d5ba0523ce085fbce8ea3f84e3459b45dc555a70b0f6cf1c5c45d42e17f` | `4c43e71cf2a5f9acea04500d5379116c4ea82d37e01861c7a177ca223488e51a` |
| Bytes of that C | 23,060,412 | 22,566,745 (−2.1%) |

- Both Bs come from the pinned seed through `scripts/blorp2-compiler-bootstrap`.
- Machine: Apple M4, Apple clang 21.0.0, load average 5 to 9 from other sessions.
- Every run was serial.
- Raw samples are in the ignored `build/borrowed_projections/` of the branch worktree.
- After the review fixes, the branch B again wrote byte-identical C for main's source, so the measurements still hold.

## Ceilings

| Metric | Ceiling | Measured |
| --- | --- | --- |
| Fixed workload: output C | identical | identical (`cde87d5b…`, which is also main B's own C) |
| Fixed workload: atomic RC operations | −15% or better | 305,171,544 → 232,619,454 (−23.8%) |
| Fixed workload: retired instructions, -O2, best of 5 | −4% or better | 12,757,414,627 → 12,041,236,433 (−5.6%) |
| Fixed workload: allocations | no higher | 14,809,595 → 14,809,595 |
| Fixed workload: List slots copied | no higher | 27,290,830 → 27,290,830 |
| Fixed workload: String bytes copied | no higher | 32,346,791 → 32,346,791 |
| Pass cost: B on main's source, instructions, -O0, best of 5 | at most +0.5% | 42,267,469,215 → 42,106,368,012 (−0.4%) |
| Pass cost: B on main's source, allocations | at most +0.5% | 14,809,595 → 14,724,734 (−0.6%) |
| Production lines, net | at most +130 | +83 (+107 / −24, all in `own/own.brp`) |

**Fixed workload.** Each B compiles main's compiler source, and both
resulting programs then compile main's source. They do the same work and
write the same C, so the comparison isolates `own`'s placement. Cycles, best
of 5, went from 3,228M to 2,890M (−10.5%); cycle counts are noisy.

**Copies.** The totals are equal, but 6.95M List slots moved from "shared
fallback" to "borrowed update". Such a field was already shared, so its copy
only changed path.

**Arms and match-tailed loop blocks.** Reviewing the change found one case to
exclude. A field read at the step where its parent's obligation ends, and
read again inside that step's arms, could otherwise make an arm acquire the
parent instead of moving it into an owned call. The same applies to fields
read in a loop block whose tail is a match, such as a `while` condition,
whose arms take the block's owners. Both cases now acquire the field, as
before.
Borrowing there had saved 0.77M atomic operations (231,851,630 before the
exclusion), 0.25% of main's.

**Line counts.**
- Production: own +107 / −24.
- Tests: +707 in two new suites, 2 Makefile lines, and −47 for the removed deferred test.

## Commands

The fixed-workload method of the [moves summary](blorp_2_ownership_moves_2026-11-03.md#commands),
with the copies stage added:

```bash
R=build/borrowed_projections; T=$R/main_tree/blorp_2; LIB=$T/standard_library; SRC=$T/src/main.brp
git archive d2bbd1f0e blorp_2/src blorp_2/standard_library | tar -x -C $R/main_tree
scripts/blorp2-compiler-bootstrap --library-root $LIB $SRC $R/mainB.c   # main's B
cp blorp_2/build/compiler.c $R/branchB.c                                 # branch B (make -C blorp_2 test)
clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 -w $R/mainB.c -o $R/mainB -lm -lpthread    # likewise branchB, *Bdiag with =1
$R/mainB --library-root $LIB $SRC $R/C_main.c       # pass cost under /usr/bin/time -l, 5 alternating runs
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 -w $R/C_main.c -o $R/P_main -lm -lpthread  # likewise P_branch, Pd_* with =1
$R/P_main --library-root $LIB $SRC $R/out_main.c    # fixed workload, 5 alternating runs; cmp out_main.c out_branch.c
python3 -I blorp_2/scripts/attribution/instrument_rc.py --kinds $R/C_main.c $R/K_main.c
BLORP_RC_OUT=$R/rc_main.tsv $R/K_main --library-root $LIB $SRC $R/outk_main.c      # atomic RC operations
BLORP_LEAK_CHECK=strict $R/Pd_main --library-root $LIB $SRC $R/outd_main.c        # allocations
# Copies: the attribution `copies` stage applied to C_main.c, then report.py copies.
python3 -I blorp_2/scripts/attribution/instrument_copies.py $D/self.c $D/copies/statements.c
```

## Gates

- `make -C blorp_2 test`: exit 0, 1,015 PASS lines and 0 FAIL, which includes
  the strict-accounting self-compile.
- `scripts/blorp2-fixpoint --prove`, run alone: exit 0. B and C emit the same
  C, and `fixtures_identical_under_a_and_b=669`.

## Tests

**Insertion** (`test_own/test_borrowed_projections.brp`, 15 tests):
- borrowing: a borrowed parameter's fields, an unread field, nested fields,
  a record update's inherited field, and a field read before its parent moves
  into a store or a call (with the parent still moving);
- acquiring: a field outliving its dying parent, a field stored beside its
  moving parent, a field read in an arm that moves its parent into a call,
  and a `while`-condition field of a loop's local (each with the parent still
  moving), while a `while`-condition field of a parameter borrows;
- edges: a loop edge and a yield acquire a field of the parent they move, and
  a return acquires exactly once.

**Verification** (`test_verify/test_borrowed_projections.brp`, 7 tests, raw IR
written by hand):
- accepted: a two-level borrowed chain of a live parent, and a read after a
  store acquires its parent;
- rejected, each with its exact message and span: a read after the
  grandparent drops, a read after the parent moves into a store, an escape
  acquired after the parent drops, a borrow naming the wrong parent, and a
  borrowed field claiming an owner.

**Oracles proven by breaking the code.** Borrowing at every equal position
fails only the arm test, and borrowing in every match-tailed loop block fails
only the `while`-condition local test.

**Deferred suite.** `test_verify/test_managed_records.brp` does not parse, so
it is not run. Its test "unused projection acquires then drops after its
parent" pinned the old acquisition and is now removed. The running
"an unread projection neither acquires nor drops" covers the new behaviour.

## What remains

A field whose parent's last read is a sibling field read, stored a step later,
still acquires: `{ prepared | unions = value.unions, records = value.records }`.
Extending the parent's drop over such reads is a separate step.
