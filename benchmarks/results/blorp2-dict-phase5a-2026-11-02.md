# Blorp 2 Dict phase 5a, 2026-11-02

Phase 5a of [DICT_PLAN](../../blorp_2/DICT_PLAN.md): the checker's tables are keyed by
what they mean. `implementation_table` indexes accepted implementations in a
`Dict[ImplementationKey, AcceptedImplementation]` keyed by (trait, receiver head), so the
head hints, the hint constants and the bucket multimap are deleted. The checker's
`name_number`-keyed Dicts (`receiver_functions`, `receiver_clashes`,
`AdmittedReceiverScope.names`) become `Dict[NameId, ...]`.

## Change

- `dict.brp`: `combine_hash(seed, value) = (seed + value) * 1099511628211`, wrapping.
- `namespace.brp`: written `Hashable` and `DictKey` for `TypeHead`; `head_hint`'s body and
  its five constants moved here as the hash.
- `utils/names.brp`: written `Hashable` (the number) and `DictKey` for `NameId`.
- `check/model.brp`: `ImplementationKey { trait_id, head }` with written `Hashable` and
  `DictKey`; `by_key` replaces `by_head`; `family_for` is one `get`; `head_hint`,
  `hinted_rows` and the hint constants are deleted.
- `callables.brp`, `receiver_clashes.brp`: `Dict[NameId, ...]`; every `name_number` call
  removed. All converted keys were `name_number` values. `namespace.brp`'s `space_key`
  and `instantiation_paths`' `pair_key` keep their Int keys (deferred in DICT_PLAN).

Deviation from the brief's Code section: `ImplementationKey.hash` is
`combine_hash(combine_hash(0, trait_number), head hash)`. The brief's single
`combine_hash(trait_number, head hash)` is `(t + h) * p`, which is symmetric and equal
for every pair with the same sum, so it would collide by anti-diagonals. Starting from 0
and combining every part in order is not symmetric (the e2e fixture checks that swapped
fields hash apart); the library comment, README and DICT_PLAN say so.

Automatic `Equatable` does satisfy a bodyless `implements DictKey for T` for a union and
a record (scratch program, then the new fixture).

## Output identity

| Compilation | Base `B` | Candidate `B` |
| --- | --- | --- |
| Base source `blorp_2/src` | `f4752e77...` | `f4752e77...` |
| Candidate source `blorp_2/src` | `c0c950f6...` | `c0c950f6...` |

Each source's C is the same whichever `B` compiles it (`cmp`). All 664 e2e fixtures were
compiled with both `B`s: exit status, stdout, stderr and (for the 546 that emit C) the C
had 0 differences. `scripts/blorp2-fixpoint --prove` reached FIXPOINT.

## Self-compile

Base `73102b901`, candidate `7112c0d86` (this change's source; the landed commit adds only this report). Seed `blorp2-seed-0d11bd3de938`.
Per tree the seed builds `A`, `A` builds `B`; `-O0` and `-O2` link with
`-DBLORP_MEMORY_DIAGNOSTICS=0`, strict allocations on a `-O0` `=1` link. Warmup plus 3
alternating serial rounds, minimum of `/usr/bin/time -l` instructions. Raw samples:
`build/dict5a/` (ignored).

| Metric | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| `-O2` instructions | 14,825,676,179 | 14,823,368,971 | -0.02% | +0.5% |
| `-O0` instructions | 43,058,875,676 | 43,103,406,515 | +0.10% | +0.5% |
| Strict allocations | 15,047,037 | 15,087,505 | +0.27% | +1% |

The allocation rise is the `ImplementationKey` record built per `family_for` and per
`implementation_table` row.

## Lines

| File | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| `check/model.brp` | 27 | 50 | -23 |
| `namespace/namespace.brp` | 27 | 0 | +27 |
| `utils/names.brp` | 12 | 0 | +12 |
| `check/callables.brp` | 6 | 6 | 0 |
| `check/receiver_clashes.brp` | 20 | 20 | 0 |
| **`blorp_2/src`** | 92 | 76 | **+16** |

`blorp_2/src` is net positive, which misses DICT_PLAN's "implementation-table step removes
more production lines than it adds, written implementations counted". The moved hint code
is a wash; the cost is the three `implements` blocks (`TypeHead`, `ImplementationKey`,
`NameId`) and the `NameId` import. Keith waived the line ceiling for this step on
2026-11-03; 5b reuses the `TypeHead` and `NameId` implementations. Library +11 (`dict.brp`), tests +73 (the 60-line e2e
fixture, 10 in `test_dict.brp`, 2 harness lines, one comment reworded).

## Gates

- `make -C blorp_2 test`: exit 0, every strict report balanced. 950 passes; the base
  snapshot gives 948 (+1 `combine_hash` unit case, +1 record-key e2e).
- The duplicate-implementation case is the existing
  `test_implementation_table.brp` "a second family for one trait and head is rejected".
- `git diff --check`: clean.
- Deletion check: `git grep -n 'head_hint\|hinted_rows\|_HINT\b' -- blorp_2/src` and
  `git grep -n name_number -- blorp_2/src/check` match nothing.
