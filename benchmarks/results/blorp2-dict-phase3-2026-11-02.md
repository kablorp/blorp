# Blorp 2 Dict phase 3, 2026-11-02

Phase 3 of [DICT_PLAN](../../blorp_2/DICT_PLAN.md): the compiler's six
`utils/hash_map.brp` users move to the prelude `Dict`, and the stopgap and its suite
are deleted. Keys stay the same Int keys (`name_number`, `space_key`, `pair_key`,
digests, head hints).

## Users

| File | Change |
| --- | --- |
| `check/receiver_clashes.brp` | `Dict`; `D.with_capacity` for the pre-sized counts |
| `check/instantiation_paths.brp` | `Dict`; `contains` renamed `has_pair` (see below) |
| `namespace/namespace.brp` | `Dict`; `D.with_capacity(expected)`; `names.set(a, b).set(c, d)` replaces the nested `set` |
| `check/callables.brp` | `Dict`, `{}` |
| `check/model.brp` | `Dict`, `{}` |
| `specialize/specialize.brp` | `Dict`, `{}`; the `DIGEST_MODULUS` comment no longer describes HashMap's power-of-two slots |

The one non-mechanical change is the rename. `instantiation_paths.brp` had a private
`contains(paths: HashMap[Int, PathPair], ...)`. With a `Dict[Int, PathPair]` parameter the
checker rejects it: "two functions named contains can accept the same receiver", against
the prelude `Dict.contains`. Phase 1's clash scan found none because the parameter was
still a `HashMap`. It is private and used only in its module, so it became `has_pair`
(7 sites). No other module clashed.

## Provenance

- Base: `8b8fd4fc9` (pin `blorp2-seed-0d11bd3de938`). Candidate: this change on it.
  Apple M-series macOS, Apple clang. Both trees are `git archive` snapshots.
- In each tree the seed builds `A`, `A` builds `B`, and `B` is linked at `-O0` and `-O2`
  with `-DBLORP_MEMORY_DIAGNOSTICS=0`, and at `-O0` with `=1` for strict allocations. Each
  `B` compiles its own tree's `blorp_2/src` with its own library root.
- Instructions: `/usr/bin/time -l`, a warmup and 3 alternating serial rounds, minimum.
  Allocations: `BLORP_LEAK_CHECK=strict` on the diagnostics build.
- Raw samples and scripts: `build/dict3/` (ignored, not retained).

## Output identity

| Compilation | Base `B` | Candidate `B` |
| --- | --- | --- |
| Base source `blorp_2/src` | `e2772c58...` | `e2772c58...` |
| Candidate source `blorp_2/src` | `9d9e5b29...` | `9d9e5b29...` |

Each source's C is the same whichever `B` compiles it (`cmp`). The two hashes differ only
because the sources differ. Both trees' `A` and `B` C are also identical to each other.

All 665 e2e fixtures under `blorp_2/test/e2e/fixtures` were compiled with the base and the
candidate `B`: exit status, stdout, stderr and (for the 545 that emit C) the C itself were
identical, with 0 differences. 120 fixtures are rejections, and their diagnostics matched
too. `scripts/blorp2-fixpoint --prove` reached FIXPOINT (B/C source identity, A/B parity
on 665 fixtures).

## Self-compile

| Metric | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| `-O2` instructions, min of 3 | 15,321,690,336 | 14,999,352,323 | -2.10% | +0.5% |
| `-O0` instructions, min of 3 | 45,598,647,321 | 43,332,706,417 | -4.97% | +0.5% |
| Strict allocations | 15,226,984 | 15,187,717 | -0.26% | +1% |

Rounds were stable to 0.2% (`-O2` base 15,322 M to 15,345 M, candidate 14,999 M to
15,001 M). The drop is consistent with DICT_PLAN's prediction (linear rebuilds and the hash spread); the mechanism was not measured separately.

## Lines

Production in `blorp_2/src`: 83 added, 213 removed, net -130 (46,433 to 46,303 lines).

| File | Added | Removed |
| --- | ---: | ---: |
| `utils/hash_map.brp` | 0 | 124 |
| `check/receiver_clashes.brp` | 28 | 28 |
| `check/instantiation_paths.brp` | 22 | 23 |
| `namespace/namespace.brp` | 15 | 15 |
| `check/callables.brp` | 7 | 8 |
| `check/model.brp` | 6 | 7 |
| `specialize/specialize.brp` | 5 | 8 |

Tests: `test/unit/test_utils/test_hash_map.brp` (212 lines, 13 cases) and its Makefile line
are deleted; no other test built these tables. Dict's own suites cover the behaviour.

## Gates

- `make -C blorp_2 test`: exit 0, 948 passes, every strict report balanced. Before: 961
  (948 plus the 13 deleted cases; the base was not re-run).
- `scripts/blorp2-fixpoint --prove`: FIXPOINT.
- README declaration-bound messages were taken from the compiler:
  `Dict[K, V] requires K: DictKey` / `help: add DictKey to K's bounds`, and
  `Dict[(Int) -> Int, V] requires (Int) -> Int: DictKey` / `help: implement DictKey for
  (Int) -> Int, or use a type that implements it`.

## Deletion check

`git grep -n -i 'hash_map\|HashMaps\|HashMap\['` in `blorp_2` now matches only history: the
completed phases and measurements in `DICT_PLAN.md`, the one-line note in `ROADMAP.md`, and the `ARCHITECTURE_FACTS_PLAN.md`,
`ARITHMETIC_OPERATORS_PLAN.md` and `RECURSIVE_UNION_CYCLES_PLAN.md` plans, which describe
the earlier design.
