# Blorp 2 List copy floor: first-growth capacity for copying append and concat

Candidate: branch `blorp2-list-copy-floor`, one commit on base `d923ee0fd`. It builds on the
measurement in `benchmarks/results/blorp2-list-growth-2026-11-03.md` at commit `80bc3dfed`
(branch `blorp2-list-growth-measure`; read it with `git show`), which found that 1.46 M List
resizes per self-compile come from the first in-place append after a copying append.

## Change

`blorp_2/src/runtime/list.brp` only (production +21 / -2 lines, 11 of them comments):

- A shared helper `blorp_list_copy_capacity(required, maximum)` beside `blorp_list_capacity`:
  `required` is returned unchanged when it is 0 or at least `min(BLORP_LIST_DEFAULT_CAPACITY,
  maximum)`, else that floor. The clamp is the one `blorp_list_capacity` already uses.
- `allocate_growing_root` binds `const size_t capacity=blorp_list_copy_capacity(required, maximum)`
  and passes `capacity` to the existing `allocate_root`, so byte size and stored `capacity` come from
  one value and there is still one allocation site. `maximum` is the `(SIZE_MAX-sizeof root)/sizeof
  element` expression the function already checks against.
- Only the borrowed `AppendUpdate` (required `count+1`) and `ConcatUpdate` (required `first+second`)
  copies use it. `[]`, `repeat`, argv, the `set` copy, the suffix copy and literals keep exact sizes;
  an empty concat result stays capacity 0.
- `blorp_2/ROADMAP.md` "Capacity and ownership contract" is revised: the old "borrowed-copy results
  allocate their known size" is narrowed to `set` and suffix copies, with the reason.

## Tests

Added a `copy-floor` probe to `blorp_2/test/runtime/fixtures/list_reuse_test.c` and its suite entry,
plus helper assertions in the `bounds` probe. The probe checks: borrowed append on `[]` gives capacity
4 and the next three in-place appends make 0 resizes (the fifth element resizes once, to 8); append
onto 2 elements floors to 4, onto 4 elements stays exact at 5; concat of two 1-element Lists gives 4,
a 3+4 concat stays exact at 7, `[] + x` floors, `[] + []` allocates once with capacity 0; `set` and
suffix copies stay exact; a String list with spare capacity drops its owners exactly (strict balance).
`bounds` checks `blorp_list_copy_capacity` for the clamp (`maximum` 1 and 3 give 1 and 3) and for 0.
A real layout with `maximum` below 4 cannot be built from the current element catalogue, so the clamp is
tested on the helper.

| Run | Result |
| --- | --- |
| List reuse suite on base runtime text, new probe | `[FAIL] copying append and concat start at the first-growth capacity` (assert on capacity 4); 1 of 22 failed |
| Same suite on the candidate | All 22 passed |
| `make -C blorp_2 test`, base (`d923ee0fd`, archived copy) | exit 0, 950 `[PASS]`, 0 `[FAIL]`, 97-test e2e suite passed |
| `make -C blorp_2 test`, candidate | exit 0, 951 `[PASS]`, 0 `[FAIL]`, every strict leak line balanced (0 leaked) |
| `scripts/blorp2-fixpoint --prove` | FIXPOINT; 664/664 fixtures identical under A and B; components and first native e2e passed. No seed rotation needed |

No existing test pinned exact copy capacity for a borrowed append or concat.

## Output identity

- **Self compile.** Base B and candidate B each compiled the candidate `blorp_2/src`. The two Cs differ in
  562 changed lines (645 diff lines): the 4-line helper plus the 276 append and concat copy functions.
  Undoing the floor statement (276 statements, each of the two `(size_t)capacity` uses restored to
  `(size_t)(count+1)` or `(size_t)(first+second)`) and dropping the helper makes the candidate's C
  byte-identical to the base's (`build/copy-floor/reverse_floor.py`). Nothing else differs.
- **Fixtures.** All 664 e2e fixtures through both Bs (`build/copy-floor/identity_fixtures.py`, serial):
  compiler exit status, stdout and stderr identical for all 664. 118 emit no C (rejections and
  non-main modules); 380 emit byte-identical C; 166 differ only by the floor. For those 166, both Cs
  linked with ASan and UBSan and ran from an empty directory: exit status, stdout and stderr identical
  in a normal run, and exit status, stdout and stderr (with the allocator byte total masked) identical
  under `BLORP_LEAK_CHECK=strict`. 0 failures.

## Self-compile

Workload: `blorp_2/src/main.brp` of the candidate tree compiled by each measured binary (identical
input for both). Each binary is built from the C its own B emits for its own source: base from B on the
`d923ee0fd` tree (its C is sha256 `c0c950f6...`, the same as the measurement report's self C), candidate
from B on the candidate tree (`b89b18d4...`). Seed `blorp2-seed-0d11bd3de938`; Apple clang 21.0.0, Apple
M4, macOS 26.7.1. Flags `-g -fno-omit-frame-pointer -w`, with `-DBLORP_MEMORY_DIAGNOSTICS=0` at `-O2`
and `-O0`, and `=1` for the census. One warmup, then 3 serial rounds alternating the order; minimum
of the 3 from `/usr/bin/time -l`. No other Blorp process was running at the start of each step (checked
with a poll before each, two consecutive quiet polls). Both binaries' output equals the C the same B
produced in the identity check (sha256 `1b75e99a...` base, `b89b18d4...` candidate).

| | Base | Candidate | Change |
| --- | ---: | ---: | ---: |
| `-O2` instructions retired (min) | 14,807,014,012 | 14,106,356,621 | **-4.73%** |
| `-O0` instructions retired (min) | 43,060,924,603 | 42,358,390,906 | **-1.63%** |
| `-O2` peak RSS (min) | 203.8 MB | 213.6 MB | +4.84% |
| `-O0` peak RSS (min) | 206.4 MB | 220.1 MB | +6.65% |
| `-O2` peak memory footprint (min) | 150.1 MB | 159.4 MB | +6.2% |
| `-O0` peak memory footprint (min) | 151.2 MB | 164.4 MB | +8.8% |
| Strict allocations (`-O0`, diagnostics) | 15,088,886 | 15,089,994 | +0.007% |
| List resizes (allocation sites) | 1,462,698 | 538,984 | -63.2% |
| List bytes moved by resize | 299,987,520 | 214,411,776 | -28.5% |
| String resizes | 763,312 | 763,606 | unchanged |

All strict runs balanced (0 leaked). The instruction saving per removed List resize is about 759
instructions at `-O2`, matching the measurement report's 762 for F = 4. The `-O2` saving of 4.73% is
the scratch measurement's 4.79% within noise. `-O0` saves less because the other `-O0` costs dilute it.
The RSS ceiling (8%, peak RSS) holds; the `-O0` peak footprint is 8.8% above, but the same base build's
`-O2` footprint ranged 150 to 182 MB across rounds, so it is no better than RSS for this comparison. The
runtime has no deterministic peak-heap counter, so none is reported.

The census has 1,108 more allocations than the base (+0.007%) and 294 more String resizes. The
floored copies change capacity, not the count of List allocations, and the candidate's output text is
larger by the helper and 276 longer copy functions. The extra allocations are most likely the
emitter building that text: 276 copy functions times about 4 strings each is about 1,104. It is far
below the 0.1% ceiling.

## Raw data

Under the ignored `build/copy-floor/` of the worktree: `measure_o2.txt`, `measure_o0.txt` (rounds),
`measure/time_*.txt` (`/usr/bin/time -l` output), `census.txt` and `measure/sites_*.txt` (allocation sites),
`id/self.diff`, `identity_fixtures.log`, `make_test_base.log`, `make_test_cand.log`, `fixpoint.log` and
the scripts that produced them.
