# Blorp 2 IR step 2b: record update facts and the record owner from the form, 2026-10-14

Checking already publishes an update's `replacements` (written order, which is evaluation order) and
`inherited` fields (declaration order) and guarantees at construction that together they name each declared
field exactly once (`plan_record_update` rejects duplicates and builds the inherited fields as the
complement). `CheckedRecordUpdate` now documents that guarantee. Lowering therefore appends the replacement
values and then the inherited reads into one `ConstructRecordValue`; the ordinal slot table, the completeness
walk and `invalid_update` are deleted. Specialization reads a record construction's or update's declaration
from its form's `RecordId` and only the type arguments from its checked type.

## Provenance

- Baseline: `origin/main` `cfc83f1ca`, `blorp_2/` exported with `git archive`, compiled with the same
  `bin/blorp` (build status FRESH) and `clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`. Compiler binary SHA-256
  `5a16e111f625a9f82fc0b8f10800cc9c93f5149387b24b93bead65eeab5a5a7d`.
- Candidate: the 2b commit on that base. Binary SHA-256
  `e1534151fc78a6d89076cecceb33a8c90995b15e511785e7a56ea626ccee8671`; sources `lower.brp` `08e5712d…`,
  `specialize.brp` `e840dcf0…`, `check_model.brp` `0db15ebe…`.
- Toolchain: Apple clang 21.0.0, arm64, macOS 26.7.1. Serial alternated runs, three each; allocations
  (`BLORP_LEAK_CHECK=strict`) are deterministic, retired instructions (`/usr/bin/time -l`, minimum of three)
  are a local proxy. Scripts (`compare.py`, `native.py`, `initializer_order.py`, `cost.py`) and raw outputs are
  in the session scratchpad.

## Output identity

- Compiler outputs, all 334 fixtures (299 compile, 35 rejected), including the new
  `record/update/managed_reorder`: exit status, stdout and stderr identical for every fixture; generated C
  identical for 330.
- Three update fixtures differ only in initializer order: `record/update/order`, `record/update/aliases` and
  `record/update/escaped_children`. Their only differing statements are `blorp_record_make_*` calls, which
  become identical once each compound literal's designated initializers are sorted (1, 1 and 2 statements).
- `record/update/managed_reorder` replaces two managed fields out of declaration order
  (`{ old | values = repeat(3, 1), text = 7.to_string() }`). Ownership insertion acquires stored children
  and numbers owners in field-vector order, so its C also retains the two children in the other order and
  swaps `blorp_owner_3` and `blorp_owner_4`, besides the initializer order. That fixture is new; it pins this
  case on the leak-checked e2e path.
- Native behaviour: every compiled fixture, built at -O0 by both compilers and run serially with empty stdin,
  gives identical stdout, stderr and exit status (299 fixtures, 0 differences).
- Memory: the four update fixtures with changed C pass the e2e native path (ASan and UBSan,
  `-fno-sanitize-recover=all`) in both builds. LeakSanitizer is not supported on macOS arm64, so leaks were
  checked with `leaks --atExit` on plain -O0 builds: 0 leaks, 0 bytes, for all four in both builds.

`record/update/order`, `{ traced_base() | text = traced_text(), number = traced_number() }`:

```c
// baseline
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_0=blorp_vl_2,.blorp_rf_0_1=blorp_vl_1,.blorp_rf_0_2=blorp_vl_3})
// candidate
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_1=blorp_vl_1,.blorp_rf_0_0=blorp_vl_2,.blorp_rf_0_2=blorp_vl_3})
```

`record/update/escaped_children` (two sites, same change):

```c
// baseline
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_0=blorp_vl_4,.blorp_rf_0_1=blorp_vl_3,.blorp_rf_0_2=blorp_vl_5})
// candidate
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_1=blorp_vl_3,.blorp_rf_0_0=blorp_vl_4,.blorp_rf_0_2=blorp_vl_5})
```

`record/update/managed_reorder`:

```c
// baseline: retain text (owner 3), take values (owner 4), then construct
blorp_string_retain(blorp_vl_6); struct blorp_string* const blorp_owner_3=blorp_vl_6; ...
struct blorp_l_0_i* const blorp_owner_4=blorp_vl_4; ...
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_0=blorp_vl_7,.blorp_rf_0_1=blorp_vl_6,.blorp_rf_0_2=blorp_vl_4})
// candidate: take values (owner 3), retain text (owner 4), then construct
struct blorp_l_0_i* const blorp_owner_3=blorp_vl_4; ...
blorp_string_retain(blorp_vl_6); struct blorp_string* const blorp_owner_4=blorp_vl_6; ...
blorp_record_make_0((struct blorp_r_0){.blorp_rf_0_2=blorp_vl_4,.blorp_rf_0_1=blorp_vl_6,.blorp_rf_0_0=blorp_vl_7})
```

## Cost

| fixture | allocations | instructions |
| --- | --- | --- |
| record/aliases | 8,418 -> 8,420 (+0.02%) | -0.28% |
| record/update/order | 14,281 -> 14,283 (+0.01%) | -0.38% |
| record/update/managed_reorder | 17,836 -> 17,838 (+0.01%) | -0.11% |

All within ±1%; e2e ceilings unchanged and passing. The new fixture's ceilings (24,000 allocations,
100M instructions) are about 30% above its own measured run. The remaining +2 allocations per compile are
lowering's `BuiltFields` result (one per record construction). A first candidate routed non-generic record
types through `concrete_record`, which translated an empty argument list with a closure on every
translation: +10 on `record/aliases`. Non-generic records now use the direct lookup, in `concrete_type` and in
`record_instance`. Keeping the direct lookup only in `concrete_type` measured +4.

## Size

Production lines, formatted copies (`bin/blorp format`), non-blank and non-comment:

| file | before | after | delta |
| --- | --- | --- | --- |
| lower.brp | 659 | 628 | -31 |
| specialize.brp | 1,708 | 1,718 | +10 |
| check_model.brp | 387 | 387 | 0 (doc comment only) |

The owner signed off specialization's growth. It replaces a re-derivation of the record owner from the
checked type with a read of the declaration the form publishes, which needs a declaration-keyed lookup
(`concrete_record`, factored out of `concrete_type`'s generic branch), the argument read (`record_instance`,
which holds the one remaining guard) and direct lookups for non-generic records. All three sites share
`lookup_record_instance`. The single-use `concrete_record_owner` is inlined into the field read, the only
place that still takes a record instance from a type. Lowering and specialization together lose 21 lines.
Tests change in 3 files (92 lines added, 22 removed), plus the new fixture.
