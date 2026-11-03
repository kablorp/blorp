# Blorp 2 Dict phase 4, 2026-11-02

Phase 4 of [DICT_PLAN](../../blorp_2/DICT_PLAN.md): `utils/names.brp` interns names
through one `Dict[String, NameId]` (`by_spelling`) instead of a `spellings` List plus a
derived bucket index. An ID is still its spelling's position, now the position among the
Dict's keys, and the Dict's value is that same ID, written by the one `set` that adds the
key. Names are never removed, so `keys()` is the stored List and positions never shift.
The public API and every caller are unchanged.

## Change

`NameRows` and `SeededWord` hold `by_spelling`. `seed_word`, `program_names`,
`same_name_table` (compares the two key lists), `name_spelling` (indexes `keys()`) and
`intern_names` use it. Deleted: `spelling_bucket`, `lookup`, `with_bucket_entry`,
`index_spellings`, `MINIMUM_BUCKETS`, `SPELLING_HASH_BASIS`, `SPELLING_HASH_PRIME`, and the
comment that described only those functions. The module's two imports (`int`, `string`)
had no remaining use and are removed.

Tests (`test_utils/test_names.brp`): `lookup survives bucket growth` is renamed `lookup
survives table growth`; the multilingual case's comment no longer names bucket
thresholds; `colliding spellings keep distinct identities` is deleted, because its
premise ("left" and "third" share a bucket of 31) no longer exists and Dict's own suite
covers collisions with a constant `Hashable`.

Docs and tools: `DICT_PLAN.md` marks phase 4 done and drops the `with_bucket_entry`
clause from the in-place-update risk; `ROADMAP.md` gains one sentence at the O1
follow-up paragraph; `scripts/attribution/report.py` drops `names.with_bucket_entry` from
`COPY_TARGETS` (`--help` still runs); a comment in `benchmarks/blorp_2/helper_accumulators.brp`
that named `with_bucket_entry` is reworded.

## Provenance

- Base: `acc2af52a`. Candidate: this change on it. Same seed pin for both
  (`blorp2-seed-0d11bd3de938`). Apple M-series macOS, Apple clang 21. Both trees are
  `git archive` snapshots.
- Per tree: the seed builds `A`, `A` builds `B`; `B` is linked at `-O0` and `-O2` with
  `-DBLORP_MEMORY_DIAGNOSTICS=0`, and at `-O0` with `=1` for strict allocations. Each `B`
  compiles its own tree's `blorp_2/src` with its own library root. In both trees `A`'s C
  and `B`'s C are byte-identical.
- Instructions: `/usr/bin/time -l`, a warmup and 3 alternating serial rounds, minimum.
  Allocations: `BLORP_LEAK_CHECK=strict` on the diagnostics build (balanced, 0 leaked).
- Raw samples and scripts: `build/dict4/` (ignored, not retained). The machine was
  shared with other sessions' builds, which slowed the staging steps; the measured
  runs were serial with no other Blorp 2 process running.

## Output identity

| Compilation | Base `B` | Candidate `B` |
| --- | --- | --- |
| Base source `blorp_2/src` | `4d083e4a...` | `4d083e4a...` |
| Candidate source `blorp_2/src` | `7e72f18e...` | `7e72f18e...` |

Each source's C is the same whichever `B` compiles it (`cmp`); the two hashes differ only
because the sources differ. All 663 e2e fixtures under `blorp_2/test/e2e/fixtures` were
compiled with both `B`s: exit status, stdout, stderr and (for the 545 that emit C) the C
had 0 differences. No `NameId` changed. `scripts/blorp2-fixpoint --prove` reached
FIXPOINT.

## Self-compile

| Metric | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| `-O2` instructions, min of 3 | 14,846,052,328 | 14,835,834,348 | -0.07% | +0.5% |
| `-O0` instructions, min of 3 | 42,934,172,856 | 42,989,699,438 | +0.13% | +0.5% |
| Strict allocations | 15,066,828 | 15,062,161 | -0.03% | +1% |

`-O2` rounds: base 14,846 M to 14,859 M, candidate 14,836 M to 14,857 M. `-O0` rounds:
base 42,934 M to 42,954 M, candidate 42,990 M to 43,173 M. The change is within noise at
`-O2`; the bucket rebuilds and the copied bucket the plan expected to save are too small a
share of a self-compile to move it measurably. The code removal is the result.

`intern_names` generated C: the loop's `set` receives the loop-carried Dict without a
preceding `dup`, so only the first new spelling copies the shared input.

## Lines

Production in `blorp_2/src`: 65 added, 175 removed, net -110, all in `utils/names.brp`
(46,223 to 46,113 `.brp` lines after rebasing onto `d49f3eec2`). Tests: `test_names.brp` 4 added, 18 removed.

## Gates

- `make -C blorp_2 test`: exit 0, 947 passes, every strict report balanced. Before: 948
  (947 plus the one deleted case).
- `scripts/blorp2-fixpoint --prove`: FIXPOINT.
- `git diff --check`: clean.

## Deletion check

`git grep -n 'spelling_bucket\|with_bucket_entry\|index_spellings\|MINIMUM_BUCKETS\|SPELLING_HASH'`
over `blorp_2` and `benchmarks` matches only history: `DICT_PLAN.md:16` (the problem
statement), `ROADMAP.md` lines 1335, 1336, 1556, 1584, 1808, 1880, 2236, 2253, 2260 (dated
measurements and the O1 follow-up note), and
`benchmarks/results/blorp_2_attribution_after_o1_2026-10-30.md`. The one live reference,
a comment in `benchmarks/blorp_2/helper_accumulators.brp:37`, was reworded in this change.
