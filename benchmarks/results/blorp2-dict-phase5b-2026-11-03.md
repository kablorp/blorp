# Blorp 2 Dict phase 5b, 2026-11-03

Phase 5b of [DICT_PLAN](../../blorp_2/DICT_PLAN.md): specialize's two **sealed** instance
tables are `Dict[UnionKey, UnionInstanceId]` and `Dict[RecordKey, RecordInstanceId]`, keyed by
their full keys, in place of two `IndexedList`s with a hand-written digest, a bucket walk and a
comparison closure. Each id is its key's position among the keys, which is also the position of
its layout in a `List` kept beside the Dict (`SealedUnions`, `SealedRecords`). The slot tables
and the function table keep `IndexedList`.

## Change

- `dict.brp`: `implements Hashable for List[Element: Hashable]` (`combine_hash` over the length,
  then each element in order) and `implements DictKey for List[Element: DictKey]`.
- `specialize.brp`: written `Hashable` for `TypeRef` (replacing `type_digest`), `RecordOrigin`,
  `UnionKey` and `RecordKey`, and `DictKey` for the two keys; `SealedUnions { ids, layouts }` and
  `SealedRecords { ids, layouts }`; `seal_unions` and `seal_records` build both in slot order, so
  the `.entries.map(... instance.layout)` projections, `seal_records`'s carried-over positions,
  `find_union_instance`, `find_record_instance` and `lookup_record_instance` are gone. A lookup is
  `ids.get(key)`; a positional read is `ids.keys().get(n)` and `layouts.get(n)`.
- The slot digests moved from `mix_digest` onto `combine_hash`; `mix_digest`, `DIGEST_MULTIPLIER`
  and `DIGEST_MODULUS` are deleted, and the `*_TYPE_DIGEST` seeds became `*_TYPE_HASH`.
  `translate_function` reads the layouts from `unions.layouts` and `records.layouts`, so its two
  layout parameters are gone.
- Sealing fails with an internal error if a slot's key is already present (the Dict would be
  shorter than `layouts` and every later id would shift). It never fires on the compiler or the
  fixtures.

Risk 1: `list.brp` cannot import `dict.brp` (`dict.brp` imports `list.brp`), so both List
implementations live in `dict.brp` beside `combine_hash`. The checker accepts an implementation
outside the module of both its trait and its type; no cycle, new module, move or seed rotation
was needed.

Deviations from the brief's Code section: `tagged_hash(tag, payload)` is a private helper for
`combine_hash(combine_hash(0, tag), payload)`, used by the `TypeRef`, `RecordOrigin` and key hashes
and the slot head digests; `lookup_record_instance` was inlined into its one caller; the layout
parameters of `translate_function` were dropped. The List hash combines the length first: folding
the elements from 0 alone gave `[]`, `[0]` and `[0, 0]` one hash, since `combine_hash(0, 0)` is 0
(review). Sealing now fails with an internal error if two complete slots share a key, where the
old tables kept both silently; no compilation or fixture reaches it.

## Output identity

| Compilation | Base `B` | Candidate `B` |
| --- | --- | --- |
| Base source `blorp_2/src` | `c0c950f6...` | `c0c950f6...` |
| Candidate source `blorp_2/src` | `462f66b8...` | `462f66b8...` |

Each source's C is the same whichever `B` compiles it (`cmp`); instance numbering is unchanged.
All 664 e2e fixtures were compiled with both `B`s: exit status, stdout, stderr and (for the 546
that emit C) the C had 0 differences. `scripts/blorp2-fixpoint --prove` reached FIXPOINT.

## Self-compile

Base `d923ee0fd` (phase 5a), candidate `8587e7da8` (this change's source; the landed commit adds
only this report). Seed `blorp2-seed-0d11bd3de938`. Per tree the seed builds `A`, `A` builds `B`;
`-O0` and `-O2` link with `-DBLORP_MEMORY_DIAGNOSTICS=0`, strict allocations on a `-O0` `=1`
link. Warmup plus 3 alternating serial rounds, minimum of `/usr/bin/time -l` instructions. Raw
samples: `build/dict5b/` (ignored).

| Metric | Base | Candidate | Change | Ceiling |
| --- | ---: | ---: | ---: | --- |
| `-O2` instructions | 14,822,117,598 | 14,767,015,011 | -0.37% | +0.5% |
| `-O0` instructions | 43,119,230,013 | 43,106,337,530 | -0.03% | +0.5% |
| Strict allocations | 15,087,505 | 14,985,735 | -0.67% | +1% |

The risk that a full `RecordKey` hash would cost instructions did not materialize, so the coarse
fallback was not measured. A lookup no longer walks a bucket through a closure, and the sealed
tables are not rebuilt from an `IndexedList` per slot.

## Lines

| Part | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| `blorp_2/src/specialize/specialize.brp` (all of `blorp_2/src`) | 203 | 212 | **-9** |
| `blorp_2/standard_library/dict.brp` (library) | 14 | 0 | +14 |
| `test_dict.brp` | 30 | 0 | +30 |
| `test_instance_digest.brp` | 33 | 23 | +10 |

`blorp_2/src` is net non-positive with the four written `Hashable` implementations counted.
Documentation: DICT_PLAN, `blorp_2/README.md` and `standard_library/README.md`.

## Gates

- `make -C blorp_2 test`: exit 0, every strict report balanced. 953 passes; the base snapshot
  gives 950 (+2 `test_dict.brp` List cases, +1 equal-nested-types case in
  `test_instance_digest.brp`).
- Oracle check: replacing the List hash's `combine_hash` fold with a plain sum fails the
  "a List hash depends on order and nesting" and "argument order and count change the hash" cases
  and nothing else.
- `git diff --check`: clean.
- Deletion check: `git grep -n 'union_instance_digest\|type_digest\|arguments_digest\|IndexedList\[UnionInstance\]\|IndexedList\[RecordInstance\]\|mix_digest\|DIGEST_MODULUS\|DIGEST_MULTIPLIER' -- blorp_2`
  matches nothing outside two historical plans (`CLEANUP_ROADMAP.md` still describes
  `type_digest`; `ARCHITECTURE_FACTS_PLAN.md` still mentions record sealing preserving digests).

## Candidate: the function table

`IndexedList[FunctionRequest]`, keyed by `InstanceKey`, stays, with `body_digest`. It is the
expansion worklist (`while cursor < prepared.functions.entries.length()`), not a sealed table. Its
key holds `List[Checked.TypeRef]` and `CallableMode`, which need written hashes for check's
`TypeRef` and for `KnownCallable`. And `runtime_instance` (six translation call sites) is not a
full-key lookup: it matches body and arguments with "every callable runtime". Moving it is a
separate step.
